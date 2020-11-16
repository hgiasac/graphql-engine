package nativedb

import (
	"fmt"
	"sync"

	nurl "net/url"

	"github.com/hasura/graphql-engine/cli/migrate/database"
	log "github.com/sirupsen/logrus"
)

var driversMu sync.RWMutex
var drivers = make(map[string]Driver)

// DatabaseDriver is the interface every database driver must implement.
// This interface is used as simple interface for SQL execution
type Driver interface {

	// Open returns a new driver instance configured with parameters
	// coming from the URL string. Migrate will call this function
	// only once per instance.
	Open(url string, logger *log.Logger) (Driver, error)

	// Close closes the underlying database instance managed by the driver.
	// Migrate will call this function only once per instance.
	Close() error

	database.MigrationExecutionDriver
}

// Open returns a new driver instance.
func Open(url string, logger *log.Logger) (Driver, error) {
	u, err := nurl.Parse(url)
	if err != nil {
		log.Debug(err)
		return nil, err
	}

	driversMu.RLock()
	if u.Scheme == "" {
		return nil, fmt.Errorf("database driver: invalid URL scheme")
	}
	driversMu.RUnlock()

	d, ok := drivers[u.Scheme]
	if !ok {
		return nil, fmt.Errorf("database driver: unknown driver %v", u.Scheme)
	}

	if logger == nil {
		logger = log.New()
	}

	return d.Open(url, logger)
}

func Register(name string, driver Driver) {
	driversMu.Lock()
	defer driversMu.Unlock()
	if driver == nil {
		panic("Register driver is nil")
	}
	if _, dup := drivers[name]; dup {
		panic("Register called twice for driver " + name)
	}
	drivers[name] = driver
}
