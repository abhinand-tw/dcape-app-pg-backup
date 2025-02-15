# dcape-app-pg-backup Makefile

SHELL               = /bin/bash
CFG                ?= .env

# Process backups
BACKUP_ENABLED     ?= no
# Backup database name(s)
DB_NAME            ?= template1
# Cron args
BACKUP_CRON        ?= 10 5 * * *
# The address to which error messages will be sent
# to change address you need delete file /etc/cron.d/backup,
# change address and update deploy 
EMAIL_ADMIN        ?= admin@domain.local

# dcape container name prefix
DCAPE_PROJECT_NAME ?= dcape
# dcape postgresql container name
DCAPE_DB           ?= $(DCAPE_PROJECT_NAME)_db_1

define CONFIG_DEF
# ------------------------------------------------------------------------------
# dcape-app-backup-pg settings

# Process backups
BACKUP_ENABLED=$(BACKUP_ENABLED)

# Backup database name(s)
DB_NAME=$(DB_NAME)
# Cron args
BACKUP_CRON=$(BACKUP_CRON)
# The address to which error messages will be sent
# to change address you need delete file /etc/cron.d/backup,
# change address and update deploy 
EMAIL_ADMIN=$(EMAIL_ADMIN)

# dcape postgresql container name
DCAPE_DB=$(DCAPE_DB)

endef
export CONFIG_DEF

# ------------------------------------------------------------------------------
# Create script
# DCAPE_DB_DUMP_DEST must be set in pg container

define EXP_SCRIPT
[[ "$$DCAPE_DB_DUMP_DEST" ]] || { echo "DCAPE_DB_DUMP_DEST not set. Exiting" ; exit 1 ; } ; \
WEEK_PARITY=$$(($$(date +%U) %2)); \
DAY_TO_PROC=4; \
DAY_OF_MONTH=$$(date +%d); \
DAY_OF_WEEK=$$(date +%u); \
MONTH_TO_KEEP=(1 * 30); \
WEEKS_TO_KEEP=(2 * 7); \
DAYS_TO_KEEP=3; \
find $$DCAPE_DB_DUMP_DEST -type f -mtime +$$MONTH_TO_KEEP -name "*-monthly.tgz" | xargs --no-run-if-empty 'rm -f' ';' \
find $$DCAPE_DB_DUMP_DEST -type f -mtime +$$WEEKS_TO_KEEP -name "*-weekly.tgz" | xargs --no-run-if-empty 'rm -f' ';' \
find $$DCAPE_DB_DUMP_DEST -type f -mtime +$$DAYS_TO_KEEP -name "*-daily.tgz" | xargs --no-run-if-empty 'rm -f' ';' \
DBS=$$@ ; \
[[ "$$DBS" ]] || DBS=all ; \
dt=$$(date +%y%m%d) ; \
if [[ $$DBS == "all" ]] ; then \
  echo "Exporting all databases..." ; \
  DBS=$$(psql --tuples-only -P format=unaligned -U postgres  \
    -c "SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres'") ; \
fi ; \
for d in $$DBS ; do \
  echo -n "Make daily backup DBs: $$DBS" ; \
  dest=$$DCAPE_DB_DUMP_DEST/$${d%%.*}-$${dt}-daily.tgz ; \
  echo -n "$${dest}..." ; \
  [ -f $$dest ] && { echo Exist ; } ; \
  pg_dump -d $$d -U postgres -Ft | gzip > $$dest || echo "error" ; \
  echo "Daily done!" ; \
  echo -n "Make weekly backup DBs: $$DBS" ; \
  dest=$$DCAPE_DB_DUMP_DEST/$${d%%.*}-$${dt}-weekly.tgz ; \
  echo -n "$${dest}..." ; \
  [ -f $$dest ] && { echo Exist ; } ; \
  if [ $$WEEK_PARITY == "0" ]; then \
    if [[ $$DAY_OF_WEEK == $$DAY_TO_PROC ]]; then \
      pg_dump -d $$d -U postgres -Ft | gzip > $$dest || echo "error" ; \
      echo "Weekly done!" ; \
    fi; \
  fi; \
  echo -n "Make monthly backup DBs: $$DBS" ; \
  dest=$$DCAPE_DB_DUMP_DEST/$${d%%.*}-$${dt}-monthly.tgz ; \
  echo -n "$${dest}..." ; \
  [ -f $$dest ] && { echo Exist ; } ; \
  if [[ $$DAY_OF_MONTH == "03" ]]; then \
    pg_dump -d $$d -U postgres -Ft | gzip > $$dest || echo "error" ; \
    echo "Monthly done!" ; \
  fi; \
done
endef
export EXP_SCRIPT

# ------------------------------------------------------------------------------

-include $(CFG)
export

.PHONY: all $(CFG) start start-hook stop update docker-wait cron backup help

##
## Цели:
##

all: help

# ------------------------------------------------------------------------------
# webhook commands

start-hook: cron backup

stop: cleanup

update: backup

# ------------------------------------------------------------------------------
# docker

# Wait for postgresql container start
docker-wait:
	@echo -n "Checking PG is ready..."
	@until [[ `docker inspect -f "{{.State.Health.Status}}" $$DCAPE_DB` == healthy ]] ; do sleep 1 ; echo -n "." ; done
	@echo "Ok"

# ------------------------------------------------------------------------------
# DB operations

## Setup host system cron
## If need change the target "cron", you need delete file /etc/cron.d/backup
## otherwise: make cron -> make: nothing to do for cron
cron: /etc/cron.d/backup

/etc/cron.d/backup:
	echo "# Set the email to wich error message will be sent" > $@
	echo "MAILTO=$$EMAIL_ADMIN" >> $@
	echo "# Set cron command with disable STDOUT for cron sent mail only if error exist" >> $@
	echo "$$BACKUP_CRON op cd $$PWD && make backup > /dev/null" >> $@

## dump all databases or named database
backup: docker-wait
	@echo "*** $@ ***"
	@[[ "$$BACKUP_ENABLED" == "yes" ]] && echo "$$EXP_SCRIPT" | docker exec -i $$DCAPE_DB bash -s - $$DB_NAME

cleanup:
	[ -f /etc/cron.d/backup ] && rm /etc/cron.d/backup || true

# ------------------------------------------------------------------------------

## create initial config
$(CFG):
	@[ -f $@ ] || echo "$$CONFIG_DEF" > $@

# ------------------------------------------------------------------------------

## List Makefile targets
help:
	@grep -A 1 "^##" Makefile | less

##
## Press 'q' for exit
##
