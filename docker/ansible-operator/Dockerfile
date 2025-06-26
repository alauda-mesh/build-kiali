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


FROM cgr.dev/chainguard/wolfi-base

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
