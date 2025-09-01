FROM registry.access.redhat.com/ubi10-minimal:latest

# Builds a composite docker service that the "owner" needs to run. Specifically it contains the following services:
#   FDO development/test rendezvous service
#   FDO to0scheduler service
#   FDO OPS (Owner Protocol Service)
#   FDO OCS (Owner Companion Service)
#   Open-horizon ocs-api (OCS REST API)

# Building a UBI image:
#   https://access.redhat.com/articles/4238681
#   https://playbook.cloudpaklab.ibm.com/ubi-faq/#Q_Can_I_addenable_additional_package_repositories_for_UBI_images

# Note: if ENV variables are used in this Dockerfile, they can not effectively be overridden by docker run
# WORKDIR: the working dir for the 2nd half of this file, and what all of the services will run from, FDO_OCS_DB_PATH: the ocs service read this. FDO_OCS_SVC_PORT and VERBOSE can be overridden on docker run.
ENV WORKDIR=/home/fdouser
ENV FDO_OCS_DB_PATH=$WORKDIR/ocs/config/db
# These env vars are only used at runtime (by start-fdo-owner-services.sh), so can be overridden by docker run
# https://github.com/fido-device-onboard/release-fidoiot/releases
ENV FDO_OPS_PORT=8042    FDO_OCS_SVC_PORT=9008   VERBOSE=true
ENV FDO_OPS_EXTERNAL_PORT=$FDO_OPS_PORT
ENV FDO_OCS_SVC_TLS_PORT=$FDO_OCS_SVC_PORT

# Working during during the installations
WORKDIR /root

# The haveged rpm (needed by RV) is in EPEL, so add that repo: https://fedoraproject.org/wiki/EPEL
# To see the available EPEL pkgs: http://mirror.nodesdirect.com/epel/8/Everything/x86_64/Packages/
# Note: supposedly we could get this from the RHEL repo, if we go thru the right paperwork: https://developers.redhat.com/blog/2020/02/26/red-hat-simplifies-container-dev-and-redistribution-rhel-packages/
# To search for rpms (or for what rpms provides a command): http://www.rpm-find.net/linux/RPM/
# Note: libssl-dev is is required by all the fdo services on ubuntu. I think the equivalent rpm is openssl-devel
# Note: due to a bug in microdnf, using the --nodocs option causes an exit code of 141: https://github.com/rpm-software-management/microdnf/issues/50
RUN mkdir -p /run/user/$UID && \
    microdnf update -y --nodocs 1>/dev/null 2>&1 && \
    microdnf install -y --nodocs ca-certificates findutils gettext java-21-openjdk openssl procps shadow-utils tar && \
    microdnf clean all

#RUN curl -sS -o epel-release-latest-8.noarch.rpm https://dl.fedoraproject.org/pub/epel/epel-release-latest-8.noarch.rpm && \
#    rpm -i /root/epel-release-latest-8.noarch.rpm && \
#    microdnf update -y && \
#    microdnf install --nodocs -y openssl ca-certificates tar findutils shadow-utils procps openssl-devel haveged && \
#    microdnf clean all

RUN useradd -r -u 1000 -g root fdouser \
    && mkdir /home/fdouser \
    && chown -R fdouser:root /home/fdouser

# Install openjdk-11-jre. The tar.gz file is 43 MB, unpacked is 124 MB
# Note: with FDO 1.7, it is necessary to use java 11.0.4 or earlier, because there is an issue with the FDO bouncycastle version and 11.0.5 and above
#RUN curl -sS -o openjre-11_linux-x64_bin.tar.gz https://cdn.azul.com/zulu/bin/zulu11.33.15-ca-jre11.0.4-linux_x64.tar.gz && \
#RUN curl -sS -o openjre-11_linux-x64_bin.tar.gz https://cdn.azul.com/zulu/bin/zulu11.43.55-ca-jre11.0.9.1-linux_x64.tar.gz && \
#    mv zulu11.*-linux_x64 /usr/lib/jvm/openjre-11-manual-installation && \
#RUN curl -sSL -o openjre-11_linux-x64_bin.tar.gz https://github.com/AdoptOpenJDK/openjdk11-upstream-binaries/releases/download/jdk-11.0.15%2B10/OpenJDK11U-jre_x64_linux_11.0.15_10.tar.gz && \
#    sha256sum openjre-11_linux-x64_bin.tar.gz && \
#    tar xzf openjre-11_linux-x64_bin.tar.gz && \
#    rm openjre-11_linux-x64_bin.tar.gz && \
#    mkdir -p /usr/lib/jvm && \
#    mv openjdk-11.0.15_10-jre /usr/lib/jvm/openjre-11-manual-installation && \
#    update-alternatives --install /usr/bin/java java /usr/lib/jvm/openjre-11-manual-installation/bin/java 1

# this doesn't work here, because docker writes /etc/hosts when it starts the container
#RUN echo "127.0.0.1 RVFDO OwnerFDO" >> /etc/hosts

USER fdouser
WORKDIR $WORKDIR

ARG fido_device_onboard_rel_ver
ENV FIDO_DEVICE_ONBOARD_REL_VER=${fido_device_onboard_rel_ver:-1.1.10}

# Get the license file
COPY LICENSE.txt /licenses/
#${FIDO_DEVICE_ONBOARD_REL_VER} 1.1.10 still uses 1.1.5.
COPY fdo/NOTICES/* /licenses/FDOIotPlatformSDK/

# Get owner db files. The owner subdir will be created automatically by COPY
# Note: need to use uid and gid to be able to build on non-linux hosts
COPY --chown=1000:0 fdo/pri-fidoiot-v${FIDO_DEVICE_ONBOARD_REL_VER}/db $WORKDIR/pri-fidoiot-v${FIDO_DEVICE_ONBOARD_REL_VER}/db/

# Get owner service files. The owner subdir will be created automatically by COPY
# Note: need to use uid and gid to be able to build on non-linux hosts
COPY --chown=1000:0 fdo/pri-fidoiot-v${FIDO_DEVICE_ONBOARD_REL_VER}/owner $WORKDIR/pri-fidoiot-v${FIDO_DEVICE_ONBOARD_REL_VER}/owner/

# Get script files. The owner subdir will be created automatically by COPY
# Note: need to use uid and gid to be able to build on non-linux hosts
COPY --chown=1000:0 fdo/pri-fidoiot-v${FIDO_DEVICE_ONBOARD_REL_VER}/scripts $WORKDIR/pri-fidoiot-v${FIDO_DEVICE_ONBOARD_REL_VER}/scripts/


# Get OCS files
# Note: we don't want the contents of ocs/config/db, that is excluded in the .dockerignore file

# FDO_OCS_DB_PATH is where the named volume will get mounted to. Create the subdirs, and make sure we own everything
RUN mkdir -p $FDO_OCS_DB_PATH/v1/{creds,devices,values} && chown -R 1000:0 $FDO_OCS_DB_PATH

# Get our ocs-api binary, startup script, agent-install-wrapper.sh
COPY --chown=1000:0 ocs-api/ $WORKDIR/ocs-api/



# Get our startup script, agent-install-wrapper.sh
COPY --chown=1000:0 docker/start-fdo-owner-service.sh $WORKDIR/

COPY --chown=1000:0 ocs-api/scripts/*.sh $WORKDIR/scripts/

# Note: the EXPOSE stmt doesn't actually expose the port, it just serves as documentation about the -p flags docker run should use. We may override these values, so just let docker run set them.
#EXPOSE 8040  8042  9008
# RV: 8040, OPS: 8042, Our ocs-api: 9008
# Note: the OCS and to0scheduler traffic is all internal to this container, so don't need to expose 9009 and 8049, respectively

# Pass db path and ocs-api port in as env vars, so they can be set via docker run if desired
CMD $WORKDIR/start-fdo-owner-service.sh
#CMD ["bash"]
