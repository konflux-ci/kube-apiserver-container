# Builds kube-apiserver from the `kubernetes` git submodule.
#
#   git submodule update --init
#   podman build -t kube-apiserver .
#
# Version metadata defaults to the currently pinned submodule commit. Re-derive
# it after bumping the submodule:
#
#   podman build \
#     --build-arg KUBE_GIT_VERSION="$(git -C kubernetes describe --tags --match='v*')" \
#     --build-arg KUBE_GIT_COMMIT="$(git -C kubernetes rev-parse HEAD)" \
#     -t kube-apiserver .

ARG BUILDER_IMAGE=registry.access.redhat.com/ubi9/go-toolset:latest
ARG RUNTIME_IMAGE=registry.access.redhat.com/ubi9/ubi-minimal:latest

FROM ${BUILDER_IMAGE} AS builder

# Mirrors hack/lib/version.sh, which stamps these onto both version packages.
ARG KUBE_GIT_VERSION=v1.36.4-21-g4c1f91925b8
ARG KUBE_GIT_COMMIT=4c1f91925b8dc669539edeb56bda8b7056e5bbc8
ARG KUBE_GIT_TREE_STATE=clean
ARG KUBE_GIT_MAJOR=1
ARG KUBE_GIT_MINOR=36
# Fixed epoch keeps the stamped buildDate (and therefore the image) reproducible;
# pass a real timestamp if you want `/version` to report when it was built.
ARG SOURCE_DATE_EPOCH=0

# Static binary so the runtime layer needs no glibc/nss coupling, and pinned to
# the toolchain shipped in the builder image (no toolchain download at build).
ENV CGO_ENABLED=0 \
    GOOS=linux \
    GOTOOLCHAIN=local \
    GOFLAGS=-mod=vendor

WORKDIR /opt/app-root/src/kubernetes
COPY --chown=1001:0 kubernetes/ ./

RUN BUILD_DATE="$(date -u -d "@${SOURCE_DATE_EPOCH}" +'%Y-%m-%dT%H:%M:%SZ')" && \
    go build -trimpath \
      -ldflags "-s -w \
        -X 'k8s.io/client-go/pkg/version.buildDate=${BUILD_DATE}' \
        -X 'k8s.io/component-base/version.buildDate=${BUILD_DATE}' \
        -X 'k8s.io/client-go/pkg/version.gitCommit=${KUBE_GIT_COMMIT}' \
        -X 'k8s.io/component-base/version.gitCommit=${KUBE_GIT_COMMIT}' \
        -X 'k8s.io/client-go/pkg/version.gitTreeState=${KUBE_GIT_TREE_STATE}' \
        -X 'k8s.io/component-base/version.gitTreeState=${KUBE_GIT_TREE_STATE}' \
        -X 'k8s.io/client-go/pkg/version.gitVersion=${KUBE_GIT_VERSION}' \
        -X 'k8s.io/component-base/version.gitVersion=${KUBE_GIT_VERSION}' \
        -X 'k8s.io/client-go/pkg/version.gitMajor=${KUBE_GIT_MAJOR}' \
        -X 'k8s.io/component-base/version.gitMajor=${KUBE_GIT_MAJOR}' \
        -X 'k8s.io/client-go/pkg/version.gitMinor=${KUBE_GIT_MINOR}' \
        -X 'k8s.io/component-base/version.gitMinor=${KUBE_GIT_MINOR}'" \
      -o /tmp/kube-apiserver ./cmd/kube-apiserver


FROM ${RUNTIME_IMAGE}

ARG KUBE_GIT_VERSION=v1.36.4-21-g4c1f91925b8
ARG USER_UID=1001

LABEL name="kube-apiserver" \
      version="${KUBE_GIT_VERSION}" \
      summary="Kubernetes API server" \
      description="kube-apiserver built from the pinned kubernetes submodule, running unprivileged on 6443."

COPY --from=builder /tmp/kube-apiserver /usr/local/bin/kube-apiserver

# ubi-minimal has no shadow-utils, so declare the account directly. Group 0 with
# group-writable dirs keeps this working under an arbitrary OpenShift UID too.
# Deliberately no setcap on the binary: 6443 is unprivileged, so the process
# never needs CAP_NET_BIND_SERVICE.
RUN echo "kube-apiserver:x:${USER_UID}:0:kube-apiserver user:/var/lib/kubernetes:/sbin/nologin" >> /etc/passwd && \
    mkdir -p /var/lib/kubernetes /var/run/kubernetes && \
    chown -R "${USER_UID}:0" /var/lib/kubernetes /var/run/kubernetes && \
    chmod -R g=u /var/lib/kubernetes /var/run/kubernetes

USER ${USER_UID}:0
WORKDIR /var/lib/kubernetes
EXPOSE 6443

ENTRYPOINT ["/usr/local/bin/kube-apiserver"]
CMD ["--help"]
