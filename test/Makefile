#
# Test configuration. This must be done BEFORE including PGXS
#

TEST_DIR   = test
TEST_DATA  = $(TEST_DIR)/data
INST_DIR   = $(shell $(PG_CONFIG) --sharedir)/extension

# The noop plugin must be deployed before "installcheck" rule.
NOOP_EXTENSION = noop_migrator
NOOP_DATA      = $(TEST_DIR)/noop_migrator--*.sql

# Setup pg_regress options and tests.
REGRESS       ?= --schedule $(TEST_DIR)/schedules/tests.txt # could be overridden
REGRESS_OPTS   = --schedule $(TEST_DIR)/schedules/setup.txt # always run setup scripts
REGRESS_OPTS  += --inputdir=$(TEST_DIR) --outputdir=$(TEST_DIR)
REGRESS_OPTS  += --load-extension=pgtap
REGRESS_OPTS  += --load-extension=file_fdw
REGRESS_OPTS  += --load-extension=$(EXTENSION)
REGRESS_OPTS  += --load-extension=$(NOOP_EXTENSION)

# Deploy the noop plugin in extension directory.
# This step substitutes @testdata@ with the test/data directory as filename
# options must be linked to the .dat files required by some tests.
installplugin:
	@echo 'Install $(NOOP_EXTENSION) plugin'
	mkdir -p $(INST_DIR)
	install -c -m 644 $(NOOP_DATA) $(INST_DIR)
	sed -i "s;@testdata@;$(abspath $(TEST_DATA));" $(INST_DIR)/$(notdir $(NOOP_DATA))

installcheck: installplugin