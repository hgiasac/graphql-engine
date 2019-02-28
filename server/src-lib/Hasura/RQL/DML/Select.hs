module Hasura.RQL.DML.Select
  ( selectP2
  , selectAggP2
  , funcQueryTx
  , convSelectQuery
  , getSelectDeps
  , module Hasura.RQL.DML.Select.Internal
  , runSelect
  )
where

import           Data.Aeson.Types
import           Instances.TH.Lift              ()

import qualified Data.HashMap.Strict            as HM
import qualified Data.HashSet                   as HS
import qualified Data.List.NonEmpty             as NE
import qualified Data.Sequence                  as DS

import           Hasura.Prelude
import           Hasura.RQL.DML.Internal
import           Hasura.RQL.DML.Select.Internal
import           Hasura.RQL.GBoolExp
import           Hasura.RQL.Types
import           Hasura.SQL.Types

import qualified Database.PG.Query              as Q
import qualified Hasura.SQL.DML                 as S

convSelCol :: (UserInfoM m, QErrM m, CacheRM m)
           => FieldInfoMap
           -> SelPermInfo
           -> SelCol
           -> m [ExtCol]
convSelCol _ _ (SCExtSimple cn) =
  return [ECSimple cn]
convSelCol fieldInfoMap _ (SCExtRel rn malias selQ) = do
  -- Point to the name key
  let pgWhenRelErr = "only relationships can be expanded"
  relInfo <- withPathK "name" $
    askRelType fieldInfoMap rn pgWhenRelErr
  let (RelInfo _ _ _ relTab _) = relInfo
  (rfim, rspi) <- fetchRelDet rn relTab
  resolvedSelQ <- resolveStar rfim rspi selQ
  return [ECRel rn malias resolvedSelQ]
convSelCol fieldInfoMap spi (SCStar wildcard) =
  convWildcard fieldInfoMap spi wildcard

convWildcard
  :: (UserInfoM m, QErrM m, CacheRM m)
  => FieldInfoMap
  -> SelPermInfo
  -> Wildcard
  -> m [ExtCol]
convWildcard fieldInfoMap (SelPermInfo cols _ _ _ _ _) wildcard =
  case wildcard of
  Star         -> return simpleCols
  (StarDot wc) -> (simpleCols ++) <$> (catMaybes <$> relExtCols wc)
  where
    (pgCols, relColInfos) = partitionFieldInfosWith (pgiName, id) $
                            HM.elems fieldInfoMap

    simpleCols = map ECSimple $ filter (`HS.member` cols) pgCols

    mkRelCol wc relInfo = do
      let relName = riName relInfo
          relTab  = riRTable relInfo
      relTabInfo <- fetchRelTabInfo relTab
      mRelSelPerm <- askPermInfo' PASelect relTabInfo

      forM mRelSelPerm $ \rspi -> do
        rExtCols <- convWildcard (tiFieldInfoMap relTabInfo) rspi wc
        return $ ECRel relName Nothing $
          SelectG rExtCols Nothing Nothing Nothing Nothing

    relExtCols wc = mapM (mkRelCol wc) relColInfos

resolveStar :: (UserInfoM m, QErrM m, CacheRM m)
            => FieldInfoMap
            -> SelPermInfo
            -> SelectQ
            -> m SelectQExt
resolveStar fim spi (SelectG selCols mWh mOb mLt mOf) = do
  procOverrides <- fmap (concat . catMaybes) $ withPathK "columns" $
    indexedForM selCols $ \selCol -> case selCol of
    (SCStar _) -> return Nothing
    _          -> Just <$> convSelCol fim spi selCol
  everything <- case wildcards of
    [] -> return []
    _  -> convWildcard fim spi $ maximum wildcards
  let extCols = unionBy equals procOverrides everything
  return $ SelectG extCols mWh mOb mLt mOf
  where
    wildcards = lefts $ map mkEither selCols

    mkEither (SCStar wc) = Left wc
    mkEither selCol      = Right selCol

    equals (ECSimple x) (ECSimple y)   = x == y
    equals (ECRel x _ _) (ECRel y _ _) = x == y
    equals _ _                         = False

convOrderByElem
  :: (UserInfoM m, QErrM m, CacheRM m)
  => (FieldInfoMap, SelPermInfo)
  -> OrderByCol
  -> m AnnObCol
convOrderByElem (flds, spi) = \case
  OCPG fldName -> do
    fldInfo <- askFieldInfo flds fldName
    case fldInfo of
      FIColumn colInfo -> do
        checkSelOnCol spi (pgiName colInfo)
        let ty = pgiType colInfo
        if ty == PGGeography || ty == PGGeometry
          then throw400 UnexpectedPayload $ mconcat
           [ fldName <<> " has type 'geometry'"
           , " and cannot be used in order_by"
           ]
          else return $ AOCPG colInfo
      FIRelationship _ -> throw400 UnexpectedPayload $ mconcat
        [ fldName <<> " is a"
        , " relationship and should be expanded"
        ]
  OCRel fldName rest -> do
    fldInfo <- askFieldInfo flds fldName
    case fldInfo of
      FIColumn _ -> throw400 UnexpectedPayload $ mconcat
        [ fldName <<> " is a Postgres column"
        , " and cannot be chained further"
        ]
      FIRelationship relInfo -> do
        when (riType relInfo == ArrRel) $
          throw400 UnexpectedPayload $ mconcat
          [ fldName <<> " is an array relationship"
          ," and can't be used in 'order_by'"
          ]
        (relFim, relSpi) <- fetchRelDet (riName relInfo) (riRTable relInfo)
        AOCObj relInfo (spiFilter relSpi) <$>
          convOrderByElem (relFim, relSpi) rest

convSelectQ
  :: (UserInfoM m, QErrM m, CacheRM m)
  => FieldInfoMap  -- Table information of current table
  -> SelPermInfo   -- Additional select permission info
  -> SelectQExt     -- Given Select Query
  -> (PGColType -> Value -> m S.SQLExp)
  -> m AnnSel
convSelectQ fieldInfoMap selPermInfo selQ prepValBuilder = do

  annFlds <- withPathK "columns" $
    indexedForM (sqColumns selQ) $ \case
    (ECSimple pgCol) -> do
      colInfo <- convExtSimple fieldInfoMap selPermInfo pgCol
      return (fromPGCol pgCol, FCol colInfo Nothing)
    (ECRel relName mAlias relSelQ) -> do
      annRel <- convExtRel fieldInfoMap relName mAlias relSelQ prepValBuilder
      return ( fromRel $ fromMaybe relName mAlias
             , either FObj FArr annRel
             )

  -- let spiT = spiTable selPermInfo

  -- Convert where clause
  wClause <- forM (sqWhere selQ) $ \be ->
    withPathK "where" $
    convBoolExp' fieldInfoMap selPermInfo be prepValBuilder

  annOrdByML <- forM (sqOrderBy selQ) $ \(OrderByExp obItems) ->
    withPathK "order_by" $ indexedForM obItems $ mapM $
    convOrderByElem (fieldInfoMap, selPermInfo)

  let annOrdByM = NE.nonEmpty =<< annOrdByML

  -- validate limit and offset values
  withPathK "limit" $ mapM_ onlyPositiveInt mQueryLimit
  withPathK "offset" $ mapM_ onlyPositiveInt mQueryOffset

  let tabFrom = TableFrom (spiTable selPermInfo) Nothing
      tabPerm = TablePerm (spiFilter selPermInfo) mPermLimit
  return $ AnnSelG annFlds tabFrom tabPerm $
    TableArgs wClause annOrdByM mQueryLimit
    (S.intToSQLExp <$> mQueryOffset) Nothing

  where
    mQueryOffset = sqOffset selQ
    mQueryLimit = sqLimit selQ
    mPermLimit = spiLimit selPermInfo

convExtSimple
  :: (UserInfoM m, QErrM m)
  => FieldInfoMap
  -> SelPermInfo
  -> PGCol
  -> m PGColInfo
convExtSimple fieldInfoMap selPermInfo pgCol = do
  checkSelOnCol selPermInfo pgCol
  askPGColInfo fieldInfoMap pgCol relWhenPGErr
  where
    relWhenPGErr = "relationships have to be expanded"

convExtRel
  :: (UserInfoM m, QErrM m, CacheRM m)
  => FieldInfoMap
  -> RelName
  -> Maybe RelName
  -> SelectQExt
  -> (PGColType -> Value -> m S.SQLExp)
  -> m (Either ObjSel ArrSel)
convExtRel fieldInfoMap relName mAlias selQ prepValBuilder = do
  -- Point to the name key
  relInfo <- withPathK "name" $
    askRelType fieldInfoMap relName pgWhenRelErr
  let (RelInfo _ relTy colMapping relTab _) = relInfo
  (relCIM, relSPI) <- fetchRelDet relName relTab
  annSel <- convSelectQ relCIM relSPI selQ prepValBuilder
  case relTy of
    ObjRel -> do
      when misused $ throw400 UnexpectedPayload objRelMisuseMsg
      return $ Left $ AnnRelG (fromMaybe relName mAlias) colMapping annSel
    ArrRel ->
      return $ Right $ ASSimple $ AnnRelG (fromMaybe relName mAlias)
               colMapping annSel
  where
    pgWhenRelErr = "only relationships can be expanded"
    misused      =
      or [ isJust (sqWhere selQ)
         , isJust (sqLimit selQ)
         , isJust (sqOffset selQ)
         , isJust (sqOrderBy selQ)
         ]
    objRelMisuseMsg =
      mconcat [ "when selecting an 'obj_relationship' "
              , "'where', 'order_by', 'limit' and 'offset' "
              , " can't be used"
              ]

partAnnFlds
  :: [AnnFld]
  -> ([(PGCol, PGColType)], [Either ObjSel ArrSel])
partAnnFlds flds =
  partitionEithers $ catMaybes $ flip map flds $ \case
  FCol c _ -> Just $ Left (pgiName c, pgiType c)
  FObj o -> Just $ Right $ Left o
  FArr a -> Just $ Right $ Right a
  FExp _ -> Nothing

getSelectDeps
  :: AnnSel
  -> [SchemaDependency]
getSelectDeps (AnnSelG flds tabFrm _ tableArgs) =
  mkParentDep tn
  : fromMaybe [] whereDeps
  <> colDeps
  <> relDeps
  <> nestedDeps
  where
    TableFrom tn _ = tabFrm
    annWc = _taWhere tableArgs
    (sCols, rCols) = partAnnFlds $ map snd flds
    (objSels, arrSels) = partitionEithers rCols
    colDeps      = map (mkColDep "untyped" tn . fst) sCols
    relDeps      = map mkRelDep $ map aarName objSels
                   <> mapMaybe getRelName arrSels
    nestedDeps   = concatMap getSelectDeps $ map aarAnnSel objSels
                   <> mapMaybe getAnnSel arrSels
    whereDeps    = getBoolExpDeps tn <$> annWc
    mkRelDep rn  =
      SchemaDependency (SOTableObj tn (TORel rn)) "untyped"

    -- ignore aggregate selections to calculate schema deps
    getRelName (ASSimple aar) = Just $ aarName aar
    getRelName (ASAgg _)      = Nothing

    getAnnSel (ASSimple aar) = Just $ aarAnnSel aar
    getAnnSel (ASAgg _)      = Nothing

convSelectQuery
  :: (UserInfoM m, QErrM m, CacheRM m)
  => (PGColType -> Value -> m S.SQLExp)
  -> SelectQuery
  -> m AnnSel
convSelectQuery prepArgBuilder (DMLQuery qt selQ) = do
  tabInfo     <- withPathK "table" $ askTabInfo qt
  selPermInfo <- askSelPermInfo tabInfo
  extSelQ <- resolveStar (tiFieldInfoMap tabInfo) selPermInfo selQ
  validateHeaders $ spiRequiredHeaders selPermInfo
  convSelectQ (tiFieldInfoMap tabInfo) selPermInfo extSelQ prepArgBuilder

funcQueryTx
  :: S.FromItem -> QualifiedFunction -> QualifiedTable
  -> TablePerm -> TableArgs
  -> (Either TableAggFlds AnnFlds, DS.Seq Q.PrepArg)
  -> Q.TxE QErr RespBody
funcQueryTx frmItem fn tn tabPerm tabArgs (eSelFlds, p) =
  runIdentity . Q.getRow
  <$> Q.rawQE dmlTxErrorHandler (Q.fromBuilder sqlBuilder) (toList p) True
  where
    sqlBuilder = toSQL $
      mkFuncSelectWith fn tn tabPerm tabArgs eSelFlds frmItem

selectAggP2 :: (AnnAggSel, DS.Seq Q.PrepArg) -> Q.TxE QErr RespBody
selectAggP2 (sel, p) =
  runIdentity . Q.getRow
  <$> Q.rawQE dmlTxErrorHandler (Q.fromBuilder selectSQL) (toList p) True
  where
    selectSQL = toSQL $ mkAggSelect sel

-- selectP2 :: (QErrM m, CacheRWM m, MonadTx m, MonadIO m) => (SelectQueryP1, DS.Seq Q.PrepArg) -> m RespBody
selectP2 :: Bool -> (AnnSel, DS.Seq Q.PrepArg) -> Q.TxE QErr RespBody
selectP2 asSingleObject (sel, p) =
  runIdentity . Q.getRow
  <$> Q.rawQE dmlTxErrorHandler (Q.fromBuilder selectSQL) (toList p) True
  where
    selectSQL = toSQL $ mkSQLSelect asSingleObject sel

phaseOne
  :: (QErrM m, UserInfoM m, CacheRM m)
  => SelectQuery -> m (AnnSel, DS.Seq Q.PrepArg)
phaseOne =
  liftDMLP1 . convSelectQuery binRHSBuilder

phaseTwo :: (MonadTx m) => (AnnSel, DS.Seq Q.PrepArg) -> m RespBody
phaseTwo =
  liftTx . selectP2 False

runSelect
  :: (QErrM m, UserInfoM m, CacheRWM m, MonadTx m)
  => SelectQuery -> m RespBody
runSelect q =
  phaseOne q >>= phaseTwo
