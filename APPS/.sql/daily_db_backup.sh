#!/bin/bash

# Configuration
BACKUP_RETENTION=7
BACKUP_DIR="/home/rd/imports/APPS/.sql"
BACKUP_PREFIX="NIGHTLY_BACKUP"

# Create backup
mysqldump -u rduser -pPassword= Rivendell | gzip > "${BACKUP_DIR}/${BACKUP_PREFIX}_$(date +%Y_%m_%d).sql.gz"

# Check if backup was successful
if [ $? -eq 0 ]; then
    echo "Backup successful: ${BACKUP_DIR}/${BACKUP_PREFIX}_$(date +%Y_%m_%d).sql.gz"
else
    echo "Backup failed!"
    exit 1
fi

# Count number of existing backups
BACKUP_COUNT=$(find "$BACKUP_DIR" -name "${BACKUP_PREFIX}_*.sql.gz" | wc -l)

# Delete oldest backup if we have more than retention limit
if [ "$BACKUP_COUNT" -gt "$BACKUP_RETENTION" ]; then
    OLDEST_BACKUP=$(find "$BACKUP_DIR" -name "${BACKUP_PREFIX}_*.sql.gz" | sort | head -n 1)
    if [ -n "$OLDEST_BACKUP" ]; then
        rm "$OLDEST_BACKUP"
        echo "Deleted oldest backup: $OLDEST_BACKUP"
    else
        echo "No old backup found to delete."
    fi
else
    echo "No need to delete old backups. Current count: $BACKUP_COUNT"
fi

echo "Backup process completed"
