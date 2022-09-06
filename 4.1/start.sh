#!/bin/bash -ex

tailpid=0
replicationpid=0

stopServices() {
  service apache2 stop
  service postgresql stop
  kill $replicationpid
  kill $tailpid
}
trap stopServices SIGTERM TERM INT

/app/config.sh

if id nominatim >/dev/null 2>&1; then
  echo "user nominatim already exists"
else
  useradd -m -p ${NOMINATIM_PASSWORD} nominatim
fi

IMPORT_FINISHED=/var/lib/postgresql/14/main/import-finished

if [ ! -f ${IMPORT_FINISHED} ]; then
  /app/init.sh
  touch ${IMPORT_FINISHED}
else
  rm -f /etc/postgresql/14/main/conf.d/postgres-import.conf
  chown -R nominatim:nominatim ${PROJECT_DIR}
fi

service postgresql start

cd ${PROJECT_DIR} && sudo -E -u nominatim nominatim refresh --website --functions

service apache2 start

# start continous replication process
if [ "$REPLICATION_URL" != "" ] && [ "$FREEZE" != "true" ]; then
  # run init in case replication settings changed
  sudo -u nominatim nominatim replication --project-dir /nominatim --init
  if [ "$UPDATE_MODE" == "continuous" ]; then
    echo "starting continuous replication"
    sudo -u nominatim nominatim replication --project-dir /nominatim &> /var/log/replication.log &
    replicationpid=${!}
  elif [ "$UPDATE_MODE" == "once" ]; then
    echo "starting replication once"
    sudo -u nominatim nominatim replication --project-dir /nominatim --once &> /var/log/replication.log &
    replicationpid=${!}
  elif [ "$UPDATE_MODE" == "catch-up" ]; then
    echo "starting replication once in catch-up mode"
    sudo -u nominatim nominatim replication --project-dir /nominatim --catch-up &> /var/log/replication.log &
    replicationpid=${!}
  else
    echo "skipping replication"
  fi
fi

# fork a process and wait for it
tail -Fv /var/log/postgresql/postgresql-14-main.log /var/log/apache2/access.log /var/log/apache2/error.log /var/log/replication.log &
tailpid=${!}

echo "Warm database caches for search and reverse queries"
sudo -E -u nominatim nominatim admin --warm > /dev/null
echo "Warming finished"
wait
