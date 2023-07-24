#
# Test configuration. This must be done BEFORE including PGXS
#

TEST_DIR   = test
TEST_DATA  = $(TEST_DIR)/data
TEST_FILES = $(wildcard $(TEST_DIR)/sql/*.sql)

# the noop plugin must be deployed before "installcheck" rule.
NOOP_EXTENSION = noop_migrator
NOOP_DATA      = $(TEST_DIR)/noop_migrator--*.sql

PG_CONFIG = pg_config
SHAREDIR := $(shell $(PG_CONFIG) --sharedir)

# Setup pg_regress options and tests.
REGRESS        = setup tables indexes constraints
REGRESS_OPTS   = --inputdir=$(TEST_DIR) --outputdir=$(TEST_DIR)
REGRESS_OPTS  += --load-extension=pgtap
REGRESS_OPTS  += --load-extension=file_fdw
REGRESS_OPTS  += --load-extension=$(EXTENSION)
REGRESS_OPTS  += --load-extension=$(NOOP_EXTENSION)

installplugin:
	@echo 'Install $(NOOP_EXTENSION) plugin'
	mkdir -p $(SHAREDIR)/extension
	install -c -m 644 $(NOOP_DATA) $(SHAREDIR)/extension
	sed -i "s;@testdata@;$(abspath $(TEST_DATA));" $(SHAREDIR)/extension/$(notdir $(NOOP_DATA))

installcheck: installplugin