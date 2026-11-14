FROM alpine:3.20

# mariadb-client — дамп баз, rclone — загрузка на Яндекс.Диск по WebDAV
RUN apk add --no-cache bash mariadb-client rclone tzdata ca-certificates gzip

COPY backup.sh /usr/local/bin/backup.sh
RUN chmod 755 /usr/local/bin/backup.sh

# Контейнер запускается с read_only, кеш rclone и временные файлы идут в /tmp (tmpfs)
ENV HOME=/tmp

ENTRYPOINT ["/usr/local/bin/backup.sh"]
