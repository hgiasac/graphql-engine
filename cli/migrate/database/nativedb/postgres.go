package nativedb

import (
	"fmt"
	"io"
	"io/ioutil"
	"strconv"

	"database/sql"

	_ "github.com/lib/pq"

	log "github.com/sirupsen/logrus"
)

var (
	ErrNilConfig          = fmt.Errorf("no config")
	ErrNoDatabaseName     = fmt.Errorf("no database name")
	ErrNoSchema           = fmt.Errorf("no schema")
	ErrDatabaseDirty      = fmt.Errorf("database is dirty")
	ErrNotSupportMetadata = fmt.Errorf("not support metadata")
)

const (
	DefaultMigrationsTable = "schema_migrations"
	DefaultSchema          = "hdb_catalog"
)

func init() {
	db := PostgresDB{}
	Register("postgres", &db)
}

type PostgresConfig struct {
	conn *sql.DB
}

type PostgresDB struct {
	config *PostgresConfig
	logger *log.Logger
}

func WithInstance(config *PostgresConfig, logger *log.Logger) (Driver, error) {
	if config == nil && config.conn != nil {
		logger.Debug(ErrNilConfig)
		return nil, ErrNilConfig
	}

	hx := &PostgresDB{
		config: config,
		logger: logger,
	}

	return hx, nil
}

func (pg *PostgresDB) Open(url string, logger *log.Logger) (Driver, error) {
	if logger == nil {
		logger = log.New()
	}

	conn, err := sql.Open("postgres", url)

	if err != nil {
		return nil, err
	}

	config := &PostgresConfig{
		conn,
	}

	px, err := WithInstance(config, logger)

	if err != nil {
		logger.Debug(err)
		return nil, err
	}

	return px, nil
}

func (pg *PostgresDB) Close() error {
	_ = pg.config.conn.Close()
	pg.config.conn = nil
	// nothing do to here
	return nil
}

func (pg *PostgresDB) Run(migration io.Reader, fileType, fileName string) error {
	migr, err := ioutil.ReadAll(migration)
	if err != nil {
		return err
	}
	body := string(migr[:])
	switch fileType {
	case "sql":
		if body == "" {
			break
		}
		sqlInput := string(body)

		_, err = pg.config.conn.Exec(sqlInput)

		if err != nil {
			return fmt.Errorf("%s: ERROR. %s", fileName, err.Error())
		}

		pg.logger.Infof("%s: OK", fileName)
	case "meta":
		return ErrNotSupportMetadata
	}
	return nil
}

func (pg *PostgresDB) Lock() error {
	// nothing do to here
	return nil
}

func (pg *PostgresDB) UnLock() error {
	// nothing do to here
	return nil
}

func (pg *PostgresDB) InsertVersion(version int64) error {
	sql := `INSERT INTO ` + fmt.Sprintf("%s.%s", DefaultSchema, DefaultMigrationsTable) + ` (version, dirty) VALUES (` + strconv.FormatInt(version, 10) + `, ` + fmt.Sprintf("%t", false) + `)`

	_, err := pg.config.conn.Exec(sql)

	return err
}

func (pg *PostgresDB) RemoveVersion(version int64) error {
	sql := `DELETE FROM ` + fmt.Sprintf("%s.%s", DefaultSchema, DefaultMigrationsTable) + ` WHERE version = ` + strconv.FormatInt(version, 10)

	_, err := pg.config.conn.Exec(sql)

	return err
}

func (pg *PostgresDB) ResetQuery() {}
