EXTENSION = db_migrator
DATA = db_migrator--*.sql
DOCS = README.db_migrator
REGRESS = 

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

all:
	@echo 'Nothing to be built.  Run "make install".'
