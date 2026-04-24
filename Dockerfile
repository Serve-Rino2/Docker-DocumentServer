ARG BASE_VERSION=24.04
FROM ubuntu:$BASE_VERSION AS documentserver
LABEL maintainer="Ascensio System SIA <support@onlyoffice.com>"

ARG BASE_VERSION
ARG PG_VERSION=16
ARG ONLYOFFICE_VALUE=onlyoffice
ENV LC_ALL=en_US.UTF-8 LANGUAGE=en_US:en DEBIAN_FRONTEND=noninteractive PG_VERSION=$PG_VERSION

RUN printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d && \
    # Bootstrap: minimal tools + locale + repo keys
    apt-get -y update && apt-get -yq install curl gnupg locales && locale-gen ${LC_ALL} && \
    # Add Microsoft repo (mssql-tools)
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor -o /usr/share/keyrings/microsoft-prod.gpg && \
    curl -fsSLo /etc/apt/sources.list.d/mssql-release.list "https://packages.microsoft.com/config/ubuntu/${BASE_VERSION}/prod.list" && \
    # Add ONLYOFFICE repo (mscore fonts)
    curl -fsSL https://download.onlyoffice.com/GPG-KEY-ONLYOFFICE | gpg --dearmor -o /usr/share/keyrings/onlyoffice.gpg && \
    echo "deb [signed-by=/usr/share/keyrings/onlyoffice.gpg] http://download.onlyoffice.com/repo/debian squeeze main" > /etc/apt/sources.list.d/onlyoffice.list && \
    # Install runtime packages
    apt-get -y update && ACCEPT_EULA=Y apt-get -yq install --no-install-recommends \
        $(: system tools)    sudo cron netcat-openbsd unzip supervisor \
        $(: databases)       postgresql redis-server rabbitmq-server \
        $(: db connectors)   mysql-client mssql-tools18 unixodbc $(apt-cache pkgnames libaio1 | sort -r | head -1) && \
    rm -rf /var/lib/apt/lists/* && \
    # Tune services for container environment
    echo 'SERVER_ADDITIONAL_ERL_ARGS="+S 1:1"' >> /etc/rabbitmq/rabbitmq-env.conf && \
    sed -i 's/^\(bind\) .*/\1 127.0.0.1/' /etc/redis/redis.conf && \
    pg_conftool $PG_VERSION main set listen_addresses 'localhost' && \
    # Install Oracle Instant Client
    ORACLE_DOWNLOAD_URL="https://download.oracle.com/otn_software/linux/instantclient/2370000" ORACLE_FILE_SUFFIX="23.7.0.25.01" ORACLE_VER_DIR="23_7" && \
    curl -fsSLo basiclite.zip ${ORACLE_DOWNLOAD_URL}/instantclient-basiclite-linux.$(dpkg --print-architecture | sed 's/amd64/x64/')-${ORACLE_FILE_SUFFIX}.zip && unzip -o basiclite.zip -d /usr/share && rm -f basiclite.zip && \
    curl -fsSLo sqlplus.zip ${ORACLE_DOWNLOAD_URL}/instantclient-sqlplus-linux.$(dpkg --print-architecture | sed 's/amd64/x64/')-${ORACLE_FILE_SUFFIX}.zip && unzip -o sqlplus.zip -d /usr/share && rm -f sqlplus.zip && \
    mv /usr/share/instantclient_${ORACLE_VER_DIR} /usr/share/instantclient && \
    find /usr/lib /lib -name "libaio.so.1*" ! -name "libaio.so.1" -exec bash -c 'ln -sf "$0" "$(dirname "$0")/libaio.so.1"' {} \;

EXPOSE 80 443

COPY run-document-server.sh        /app/ds/run-document-server.sh
COPY config/supervisor/supervisor  /etc/init.d/
COPY config/supervisor/ds/*.conf   /etc/supervisor/conf.d/
COPY oracle/sqlplus                /usr/bin/sqlplus
COPY fonts/                        /usr/share/fonts/truetype/

ARG COMPANY_NAME=onlyoffice
ARG PRODUCT_NAME=documentserver
ARG PRODUCT_EDITION=
ARG PACKAGE_VERSION=
ARG TARGETARCH
ARG PACKAGE_BASEURL="http://download.onlyoffice.com/install/documentserver/linux"
ENV COMPANY_NAME=$COMPANY_NAME PRODUCT_NAME=$PRODUCT_NAME PRODUCT_EDITION=$PRODUCT_EDITION \
    DS_PLUGIN_INSTALLATION=false DS_DOCKER_INSTALLATION=true

RUN PACKAGE_FILE="${COMPANY_NAME}-${PRODUCT_NAME}${PRODUCT_EDITION}${PACKAGE_VERSION:+_$PACKAGE_VERSION}_${TARGETARCH:-$(dpkg --print-architecture)}.deb" && \
    curl -fsSLo /tmp/$PACKAGE_FILE "$PACKAGE_BASEURL/$PACKAGE_FILE" && \
    service postgresql start && \
    sudo -u postgres psql -c "CREATE USER $ONLYOFFICE_VALUE WITH password '$ONLYOFFICE_VALUE';" -c "CREATE DATABASE $ONLYOFFICE_VALUE OWNER $ONLYOFFICE_VALUE;" && \
    apt-get -y update && apt-get -yq install --no-install-recommends /tmp/$PACKAGE_FILE && \
    sudo -u postgres psql -c "DROP DATABASE $ONLYOFFICE_VALUE;" -c "DROP ROLE $ONLYOFFICE_VALUE;" && \
    service postgresql stop && \
    [ "$(find /usr/share/fonts/truetype/msttcorefonts -maxdepth 1 -type f -iname '*.ttf' | wc -l)" -ge 30 ] || { echo 'msttcorefonts failed to download'; exit 1; } && \
    case "$PRODUCT_EDITION" in -ee|-de) ;; *) rm -f /etc/supervisor/conf.d/ds-adminpanel.conf && sed -i 's/,adminpanel//' /etc/supervisor/conf.d/ds.conf ;; esac && \
    chmod 755 /etc/init.d/supervisor /app/ds/*.sh && \
    sed -i "s/COMPANY_NAME/${COMPANY_NAME}/g" /etc/supervisor/conf.d/*.conf && \
    DS_SCHEMA="/var/www/$COMPANY_NAME/documentserver/server/schema" && \
    printf '\nGO'   | tee -a "$DS_SCHEMA/mssql/createdb.sql"  >> "$DS_SCHEMA/mssql/removetbl.sql" && \
    printf '\nexit' | tee -a "$DS_SCHEMA/oracle/createdb.sql" >> "$DS_SCHEMA/oracle/removetbl.sql" && \
    rm -rf /tmp/$PACKAGE_FILE /var/log/$COMPANY_NAME /var/lib/apt/lists/*

VOLUME /var/log/$COMPANY_NAME /var/lib/$COMPANY_NAME /var/www/$COMPANY_NAME/Data /var/lib/postgresql /var/lib/rabbitmq /var/lib/redis /usr/share/fonts/truetype/custom

ENTRYPOINT ["/app/ds/run-document-server.sh"]
