# syntax=docker/dockerfile:experimental
ARG ZM_VERSION=master
ARG S6_ARCH=amd64
#####################################################################
#                                                                   #
# Download Zoneminder Source Code                                   #
# Parse control file for all runtime and build dependencies         #
#                                                                   #
#####################################################################
FROM python:alpine as zm-source
ARG ZM_VERSION
WORKDIR /zmsource

RUN set -x \
    && apk add \
        git \
    && git clone https://github.com/ZoneMinder/zoneminder.git . \
    && git submodule update --init --recursive \
    && git checkout ${ZM_VERSION} \
    && git submodule update --init --recursive

COPY parse_control.py .

# This parses the control file located at distros/ubuntu2004/control
# It outputs zoneminder_control which only includes requirements for zoneminder
# This prevents equivs-build from being confused when there are multiple packages
# Also outputz zoneminder_compat for shlib resolver
RUN set -x \
    && python3 -u parse_control.py

#####################################################################
#                                                                   #
# Convert rootfs to LF using dos2unix                               #
# Alleviates issues when git uses CRLF on Windows                   #
#                                                                   #
#####################################################################
FROM python:alpine as rootfs-converter
WORKDIR /rootfs

RUN set -x \
    && apk add --repository=http://dl-cdn.alpinelinux.org/alpine/edge/community/ \
        dos2unix

COPY root .
RUN find . -type f -print0 | xargs -0 -n 1 -P 4 dos2unix

#####################################################################
#                                                                   #
# Download and extract s6 overlay                                   #
#                                                                   #
#####################################################################
FROM alpine:latest as s6downloader
# Required to persist build arg
ARG S6_ARCH
WORKDIR /s6downloader

RUN set -x \
    && wget -O /tmp/s6-overlay.tar.gz "https://github.com/just-containers/s6-overlay/releases/latest/download/s6-overlay-${S6_ARCH}.tar.gz" \
    && mkdir -p /tmp/s6 \
    && tar zxvf /tmp/s6-overlay.tar.gz -C /tmp/s6 \
    && cp -r /tmp/s6/* .

RUN set -x \
    && wget -O /tmp/socklog-overlay.tar.gz "https://github.com/just-containers/socklog-overlay/releases/latest/download/socklog-overlay-${S6_ARCH}.tar.gz" \
    && mkdir -p /tmp/socklog \
    && tar zxvf /tmp/socklog-overlay.tar.gz -C /tmp/socklog \
    && cp -r /tmp/socklog/* .

#####################################################################
#                                                                   #
# Prepare base-image with core programs + repository                #
#                                                                   #
#####################################################################
FROM debian:buster as base-image-core

# Skip interactive post-install scripts
ENV DEBIAN_FRONTEND=noninteractive

RUN set -x \
    && apt-get update \
    && apt-get install -y \
        ca-certificates \
        gnupg \
        wget \
    && rm -rf /var/lib/apt/lists/*

# Required for libmp4v2-dev
RUN set -x \
    && echo "deb [trusted=yes] https://zmrepo.zoneminder.com/debian/release-1.34 buster/" >> /etc/apt/sources.list \
    && wget -O - https://zmrepo.zoneminder.com/debian/archive-keyring.gpg | apt-key add -

#####################################################################
#                                                                   #
# Build packages containing build and runtime dependencies          #
# for installation in later stages                                  #
#                                                                   #
#####################################################################
FROM base-image-core as package-builder
WORKDIR /packages

# Install base toolset
RUN set -x \
    && apt-get update \
    && apt-get install -y \
        devscripts

# Create runtime package
RUN --mount=type=bind,target=/tmp/control,source=/zmsource/zoneminder_control,from=zm-source,rw \
    equivs-build /tmp/control \
    && ls | grep -P \(zoneminder_\)\(.*\)\(\.deb\) | xargs -I {} mv {} runtime-deps.deb

# Create build-deps package
RUN --mount=type=bind,target=/tmp/control,source=/zmsource/zoneminder_control,from=zm-source,rw \
    mk-build-deps /tmp/control \
    && ls | grep -P \(build-deps\)\(.*\)\(\.deb\) | xargs -I {} mv {} build-deps.deb

#####################################################################
#                                                                   #
# Install runtime dependencies                                      #
# Does not include shared lib dependencies as those are resolved    #
# after building. Installed in final-image                          #
#                                                                   #
#####################################################################
FROM base-image-core as base-image

# Install ZM Dependencies
# Don't want recommends of ZM
RUN --mount=type=bind,target=/tmp/runtime-deps.deb,source=/packages/runtime-deps.deb,from=package-builder,rw \
    set -x \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ./tmp/runtime-deps.deb \
    && rm -rf /var/lib/apt/lists/*

#####################################################################
#                                                                   #
# Install runtime + build dependencies                              #
# Build Zoneminder                                                  #
#                                                                   #
#####################################################################
FROM package-builder as builder
WORKDIR /zmbuild
# Yes WORKDIR is overwritten but this is more a comment
# to specify the final WORKDIR

# Install ZM Buid and Runtime Dependencies
# Need to install runtime dependencies here as well
# because we don't want devscripts in the base-image
# This results in runtime dependencies being installed twice to avoid additional bloating
WORKDIR /packages
RUN set -x \
    && apt-get update \
    && apt-get install -y \
        ./runtime-deps.deb \
        ./build-deps.deb

# Install libjwt since its an optional dep not included in the control file
RUN set -x \
    && apt-get install -y \
        libjwt-dev \
        libjwt0

WORKDIR /zmbuild
RUN --mount=type=bind,target=/zmbuild,source=/zmsource,from=zm-source,rw \
    set -x \
    && cmake \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_SKIP_RPATH=ON \
        -DCMAKE_VERBOSE_MAKEFILE=OFF \
        -DCMAKE_COLOR_MAKEFILE=ON \
        -DZM_RUNDIR=/zoneminder/run \
        -DZM_SOCKDIR=/zoneminder/run \
        -DZM_TMPDIR=/zoneminder/tmp \
        -DZM_LOGDIR=/zoneminder/logs \
        -DZM_WEBDIR=/var/www/html \
        -DZM_CONTENTDIR=/data \
        -DZM_CACHEDIR=/zoneminder/cache \
        -DZM_CGIDIR=/zoneminder/cgi-bin \
        -DZM_WEB_USER=www-data \
        -DZM_WEB_GROUP=www-data \
        -DCMAKE_INSTALL_SYSCONFDIR=config \
        -DZM_CONFIG_DIR=/config \
        -DCMAKE_BUILD_TYPE=Debug \
        . \
    && make \
    && make DESTDIR="/zminstall" install

# Move default config location
RUN mv /zminstall/config /zminstall/zoneminder/defaultconfig

#####################################################################
#                                                                   #
# Resolve shlib:Depends to resolved.txt                             #
#                                                                   #
#####################################################################
FROM builder as shlibs-resolver
WORKDIR /shlibs

COPY --from=zm-source /zmsource/zoneminder_control ./debian/control
COPY --from=zm-source /zmsource/zoneminder_compat ./debian/compat

# Move zoneminder install to directory where dh_shlibdeps can find it
# Run dh_shlibdeps which will resolve all shared library dependencies
# Alternative: dpkg-shlibdeps -O debian/zoneminder/zms << Only need zms executable for now
RUN mv /zminstall ./debian/zoneminder \
    && dh_shlibdeps \
    && mv ./debian/zoneminder.substvars resolved.txt

#####################################################################
#                                                                   #
# Format resolved.txt for installation                              #
#                                                                   #
#####################################################################
FROM python:alpine as shlibs-resolved
WORKDIR /resolved

COPY --from=shlibs-resolver /shlibs/resolved.txt .
COPY parse_shlibs.py .

# This reads resolved.txt and writes resolved_installable.txt for installing
# with apt-get install
RUN set -x \
    && python3 -u parse_shlibs.py


#####################################################################
#                                                                   #
# Install ZoneMinder                                                #
# Create required folders                                           #
# Install additional dependencies                                   #
#                                                                   #
#####################################################################
FROM base-image as final-build
ARG ZM_VERSION

# Install ZM Shared Library Dependencies
RUN --mount=type=bind,target=/tmp/resolved_installable.txt,source=/resolved/resolved_installable.txt,from=shlibs-resolved,rw \
    set -x \
    && apt-get update \
    && apt-get install -y \
        $(grep -vE "^\s*#" /tmp/resolved_installable.txt  | tr "\n" " ") \
    && rm -rf /var/lib/apt/lists/*

# Install additional services required by ZM ("Recommends")
# PHP-fpm not required for apache
RUN set -x \
    && apt-get update \
    && apt-get install -y \
        apache2 \
        libapache2-mod-php \
        php-fpm \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

## Create www-data user
RUN set -x \
    && groupmod -o -g 911 www-data \
    && usermod -o -u 911 www-data

# Install ZM
COPY --chown=www-data --chmod=755 --from=builder /zminstall /

# Install s6 overlay
COPY --from=s6downloader /s6downloader /

# Copy rootfs
COPY --from=rootfs-converter /rootfs /


# Create required folders
RUN set -x \
    && mkdir -p \
        /data \
        /config \
        /zoneminder/run \
        /zoneminder/cache \
        /zoneminder/logs \
        /zoneminder/tmp \
        /log \
    && chown -R www-data:www-data \
        /data \
        /config \
        /zoneminder \
    && chmod -R 755 \
        /data \
        /config \
        /zoneminder \
        /log \
    && chown -R nobody:nogroup \
        /log

# Redirect all ZoneMinder logs to /dev/null since all logging in handled
# by socklog. This avoid overflowing the logging directory
RUN ln -sf /dev/null /zoneminder/logs/zma_m1.log \
    && ln -sf /dev/null /zoneminder/logs/zmc_m1.log \
    && ln -sf /dev/null /zoneminder/logs/zmdc.log \
    && ln -sf /dev/null /zoneminder/logs/zmfilter_1.log \
    && ln -sf /dev/null /zoneminder/logs/zmfilter_2.log \
    && ln -sf /dev/null /zoneminder/logs/zmpkg.log \
    && ln -sf /dev/null /zoneminder/logs/zmstats.log \
    && ln -sf /dev/null /zoneminder/logs/zmupdate.log \
    && ln -sf /dev/null /zoneminder/logs/zmwatch.log

# Reconfigure apache
RUN set -x \
    && rm /var/www/html/index.html \
    && a2enconf zoneminder \
    && a2enmod rewrite \
    && ln -sf /proc/self/fd/1 /var/log/apache2/access.log \
    && ln -sf /proc/self/fd/1 /var/log/apache2/error.log

LABEL \
    org.opencontainers.image.version=${ZM_VERSION}

ENV \
    S6_FIX_ATTRS_HIDDEN=1 \
    S6_BEHAVIOUR_IF_STAGE2_FAILS=2 \
    APACHE_RUN_USER=www-data \
    APACHE_RUN_GROUP=www-data \
    SOCKLOG_TIMESTAMP_FORMAT="" \
    MAX_LOG_SIZE_BYTES=1000000 \
    MAX_LOG_NUMBER=10

CMD ["/init"]
