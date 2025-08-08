#syntax=docker/dockerfile:1.4

FROM cgr.dev/chainguard/wolfi-base AS builder

RUN apk update && \
    apk add --no-cache build-base curl go-1.23 unzip

ARG ANSIBLE_OPERATOR_VERSION=v1.38.1

RUN curl -sSL https://github.com/operator-framework/ansible-operator-plugins/archive/refs/tags/${ANSIBLE_OPERATOR_VERSION}.tar.gz \
    -o /tmp/ansible-operator-plugins.tar.gz && \
    mkdir -p /tmp/ansible-operator-plugins && \
    cd /tmp/ansible-operator-plugins && \
    tar xzf /tmp/ansible-operator-plugins.tar.gz --strip-components=1

ARG GOPROXY
env GOPROXY=${GOPROXY}

RUN <<EOF
#!/bin/bash
set -euo pipefail

cd /tmp/ansible-operator-plugins

REPO=github.com/operator-framework/ansible-operator-plugins
GO_LDFLAGS="-w \
    -X ${REPO}/internal/version.Version=${ANSIBLE_OPERATOR_VERSION} \
    -X ${REPO}/internal/version.KubernetesVersion=v1.31.0 \
    -X ${REPO}/internal/version.ImageVersion=${ANSIBLE_OPERATOR_VERSION} \
    -X runtime.buildVersion=unknown -X runtime.modinfo="

go build -o /usr/local/bin/ansible-operator \
    -o ansible-operator \
    -trimpath -ldflags "${GO_LDFLAGS}" \
    ./cmd/ansible-operator
EOF

FROM cgr.dev/chainguard/wolfi-base AS baselayout

# Just make some ridiculous scanners happy
COPY <<'EOF' /etc/passwd
root:x:0:0:root:/root:/bin/ash
bin:x:1:1:bin:/bin:/sbin/nologin
daemon:x:2:2:daemon:/sbin:/sbin/nologin
adm:x:3:4:adm:/var/adm:/sbin/nologin
lp:x:4:7:lp:/var/spool/lpd:/sbin/nologin
mail:x:8:12:mail:/var/mail:/sbin/nologin
news:x:9:13:news:/usr/lib/news:/sbin/nologin
uucp:x:10:14:uucp:/var/spool/uucppublic:/sbin/nologin
man:x:13:15:man:/usr/man:/sbin/nologin
postmaster:x:14:12:postmaster:/var/mail:/sbin/nologin
cron:x:16:16:cron:/var/spool/cron:/sbin/nologin
ftp:x:21:21::/var/lib/ftp:/sbin/nologin
sshd:x:22:22:sshd:/dev/null:/sbin/nologin
nobody:x:65534:65534:nobody:/:/sbin/nologin
EOF

# Set a '*' for the root password to make scanners happy
RUN <<'EOF'
awk -F: '{
    pw = ":!:"
    if ($1 == "root") { pw = ":*:" }
    print($1 pw ":0:::::")
}' /etc/passwd > /etc/shadow
EOF


FROM cgr.dev/chainguard/wolfi-base

COPY --from=baselayout --link /etc/passwd /etc/passwd
COPY --from=baselayout --link /etc/shadow /etc/shadow

RUN mkdir -p /etc/ansible \
    && echo "localhost ansible_connection=local" > /etc/ansible/hosts \
    && echo '[defaults]' > /etc/ansible/ansible.cfg \
    && echo 'roles_path = /opt/ansible/roles' >> /etc/ansible/ansible.cfg \
    && echo 'library = /usr/share/ansible/openshift' >> /etc/ansible/ansible.cfg

ENV HOME=/opt/ansible \
    USER_NAME=ansible \
    USER_UID=1001

RUN apk update && apk add --no-cache tini python-3.12 py3.12-pip py3.12-cryptography

ENV REMOTE_SOURCES=${REMOTE_SOURCES:-"./openshift/"}
ENV REMOTE_SOURCES_DIR=${REMOTE_SOURCES_DIR:-"/cachito"}

COPY ${REMOTE_SOURCES} ${REMOTE_SOURCES_DIR}
COPY openshift/install-ansible.sh .
RUN sh ./install-ansible.sh

COPY --from=builder /tmp/ansible-operator-plugins/ansible-operator /usr/local/bin/ansible-operator
COPY openshift/release/ansible/ansible_collections ${HOME}/.ansible/collections/ansible_collections

# Ensure directory permissions are properly set
RUN echo "${USER_NAME}:x:${USER_UID}:0:${USER_NAME} user:${HOME}:/sbin/nologin" >> /etc/passwd \
  && mkdir -p ${HOME}/.ansible/tmp \
  && chown -R ${USER_UID}:0 ${HOME} \
  && chmod -R ug+rwx ${HOME}

WORKDIR ${HOME}
USER ${USER_UID}
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/ansible-operator", "run", "--watches-file=./watches.yaml"]
