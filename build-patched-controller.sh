#!/usr/bin/env bash
set -euo pipefail

TAG="${TAG:-1.14.5-p7}"
REGISTRY="${REGISTRY:-renebakx}"
ARCHES="${ARCHES:-amd64 arm64}"
CONTROLLER_IMAGE="${CONTROLLER_IMAGE:-${REGISTRY}/nginx-ingress-controller:${TAG}}"
BUILDER="${BUILDER:-ingress-nginx-local}"
REPO_INFO="${REPO_INFO:-https://github.com/rancher/ingress-nginx}"
NO_CACHE="${NO_CACHE:-true}"
PUSH="${PUSH:-true}"
BUILD_LOG_DIR="${BUILD_LOG_DIR:-build-logs}"
PROVENANCE="${PROVENANCE:-true}"
SBOM="${SBOM:-true}"

build_cache_args=()
if [[ "${NO_CACHE}" == "true" ]]; then
  build_cache_args+=(--no-cache)
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required" >&2
  exit 1
fi

if ! command -v git >/dev/null 2>&1; then
  echo "git is required" >&2
  exit 1
fi

COMMIT_SHA="${COMMIT_SHA:-$(git rev-parse --short HEAD)}"

if [[ "${PUSH}" != "true" && "$(wc -w <<<"${ARCHES}")" -ne 1 ]]; then
  echo "PUSH=false only supports a single platform with --load. Set ARCHES=amd64 or ARCHES=arm64 for local-only builds." >&2
  exit 1
fi

platforms=()
for ARCH in ${ARCHES}; do
  case "${ARCH}" in
    amd64|arm64) platforms+=("linux/${ARCH}") ;;
    *)
      echo "unsupported ARCH=${ARCH}; expected amd64 or arm64" >&2
      exit 1
      ;;
  esac
done

PLATFORMS="$(IFS=,; echo "${platforms[*]}")"

docker buildx create --name "${BUILDER}" --use >/dev/null 2>&1 || docker buildx use "${BUILDER}"
docker buildx inspect --bootstrap

for ARCH in ${ARCHES}; do
  PLATFORM="linux/${ARCH}"

  echo "Building controller binaries for ${ARCH} using Rancher's Docker build image"

  ARCH="${ARCH}" \
  PLATFORM="${PLATFORM}" \
  TAG="${TAG}" \
  COMMIT_SHA="${COMMIT_SHA}" \
  REPO_INFO="${REPO_INFO}" \
  make build
done

tmp_dockerfile="$(mktemp)"
cleanup() {
  rm -f "${tmp_dockerfile}"
}
trap cleanup EXIT

cat > "${tmp_dockerfile}" <<'DOCKERFILE'
FROM registry.suse.com/bci/bci-base:16.0 AS nginx-builder

RUN zypper addrepo -p 105 http://download.opensuse.org/distribution/leap/16.0/repo/oss/ download.opensuse.org-oss && \
    zypper --gpg-auto-import-keys refresh

COPY images/nginx/rootfs/patches /patches
COPY --chmod=0755 images/nginx/rootfs/build.sh /

RUN /build.sh

FROM registry.suse.com/bci/bci-base:16.0 AS nginx-base

ENV PATH=$PATH:/usr/local/luajit/bin:/usr/local/nginx/sbin:/usr/local/nginx/bin
ENV LUA_PATH="/usr/local/share/luajit-2.1.0-beta3/?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/lib/lua/?.lua;;"
ENV LUA_CPATH="/usr/local/lib/lua/?/?.so;/usr/local/lib/lua/?.so;;"

COPY --from=nginx-builder /usr/local /usr/local
COPY --from=nginx-builder /usr/lib64/libopentelemetry* /usr/lib64/
COPY --from=nginx-builder /usr/lib64/libbrotli* /usr/lib64/
COPY --from=nginx-builder /opt /opt
COPY --from=nginx-builder /etc/nginx /etc/nginx

RUN ln -s /usr/lib64/liblua5.3.so.5.3.0 /usr/local/lib/liblua-5.3.so

RUN zypper addrepo \
    -p 105 http://download.opensuse.org/distribution/leap/16.0/repo/oss/ download.opensuse.org-oss && \
    zypper --gpg-auto-import-keys refresh
RUN zypper install -y --allow-vendor-change \
    liblmdb-0_9_30 \
    libxml2-tools \
    libmaxminddb0 \
    libcap-progs \
    crypto-policies-scripts \
    libgrpc++1_59 \
    libatomic1 \
    grpc-devel \
    wget \
    which \
    libyajl2 \
    openssl-3 \
    libpcre1 \
    libicu77 \
    util-linux \
    liblua5_4-5 \
    libxslt-tools \
    procps \
    catatonit

RUN ldDirs=" \
      /usr/local/lib \
      /usr/local/lib64 \
  "; \
  for dir in ${ldDirs}; do \
    echo "${dir}" >>/etc/ld.so.conf.d/local.conf; \
  done
RUN /sbin/ldconfig

RUN ln -s /usr/local/nginx/sbin/nginx /sbin/nginx
RUN groupadd -rg 101 www-data && \
    useradd -u 101 -M -d /usr/local/nginx -s /sbin/nologin -G www-data -g www-data www-data

RUN writeDirs=" \
      /var/log/nginx \
      /var/lib/nginx/body \
      /var/lib/nginx/fastcgi \
      /var/lib/nginx/proxy \
      /var/lib/nginx/scgi \
      /var/lib/nginx/uwsgi \
      /var/log/audit \
  "; \
  for dir in ${writeDirs}; do \
    mkdir -p ${dir}; \
    chown -R www-data.www-data ${dir}; \
  done

FROM nginx-base

ARG TARGETARCH
ARG VERSION
ARG COMMIT_SHA
ARG BUILD_ID=UNSET

LABEL org.opencontainers.image.title="NGINX Ingress Controller for Kubernetes"
LABEL org.opencontainers.image.documentation="https://kubernetes.github.io/ingress-nginx/"
LABEL org.opencontainers.image.source="https://github.com/kubernetes/ingress-nginx"
LABEL org.opencontainers.image.vendor="The Kubernetes Authors"
LABEL org.opencontainers.image.licenses="Apache-2.0"
LABEL org.opencontainers.image.version="${VERSION}"
LABEL org.opencontainers.image.revision="${COMMIT_SHA}"
LABEL build_id="${BUILD_ID}"

WORKDIR /etc/nginx

COPY --chown=www-data:www-data rootfs/etc /etc
COPY --chown=www-data:www-data rootfs/bin/${TARGETARCH}/dbg /
COPY --chown=www-data:www-data rootfs/bin/${TARGETARCH}/nginx-ingress-controller /
COPY --chown=www-data:www-data rootfs/bin/${TARGETARCH}/wait-shutdown /

RUN bash -xeu -c ' \
  writeDirs=( \
    /etc/ingress-controller \
    /etc/ingress-controller/ssl \
    /etc/ingress-controller/auth \
    /etc/ingress-controller/geoip \
    /etc/ingress-controller/telemetry \
    /var/log \
    /var/log/nginx \
    /tmp/nginx \
  ); \
  for dir in "${writeDirs[@]}"; do \
    mkdir -p ${dir}; \
    chown -R www-data:www-data ${dir}; \
  done' \
  && echo "/lib:/usr/lib:/usr/local/lib:/modules_mount/etc/nginx/modules/otel" > /etc/ld-musl-x86_64.path \
  && echo "/lib:/usr/lib:/usr/local/lib:/modules_mount/etc/nginx/modules/otel" > /etc/ld-musl-aarch64.path

RUN setcap    cap_net_bind_service=+ep /nginx-ingress-controller \
  && setcap -v cap_net_bind_service=+ep /nginx-ingress-controller \
  && setcap    cap_net_bind_service=+ep /usr/local/nginx/sbin/nginx \
  && setcap -v cap_net_bind_service=+ep /usr/local/nginx/sbin/nginx \
  && setcap    cap_net_bind_service=+ep /usr/bin/catatonit \
  && setcap -v cap_net_bind_service=+ep /usr/bin/catatonit \
  && ln -sf /usr/local/nginx/sbin/nginx /usr/bin/nginx

USER www-data

RUN ln -sf /dev/stdout /var/log/nginx/access.log \
  && ln -sf /dev/stderr /var/log/nginx/error.log

ENTRYPOINT ["/usr/bin/catatonit", "--"]
CMD ["/nginx-ingress-controller"]
DOCKERFILE

echo "Building final controller image:"
echo "  ${CONTROLLER_IMAGE}"
echo "  platforms: ${PLATFORMS}"

output_args=(--load)
if [[ "${PUSH}" == "true" ]]; then
  output_args=(--push)
fi

attest_args=()
if [[ "${PUSH}" == "true" ]]; then
  if [[ "${PROVENANCE}" == "true" ]]; then
    attest_args+=(--provenance=mode=max)
  fi
  if [[ "${SBOM}" == "true" ]]; then
    attest_args+=(--sbom=true)
  fi
fi

mkdir -p "${BUILD_LOG_DIR}"
BUILD_LOG_FILE="${BUILD_LOG_DIR}/build-${TAG}-$(date +%Y%m%d-%H%M%S).log"
echo "Capturing build log to ${BUILD_LOG_FILE}"

set -o pipefail
docker buildx build \
  "${build_cache_args[@]}" \
  --builder "${BUILDER}" \
  --platform "${PLATFORMS}" \
  --progress=plain \
  "${output_args[@]}" \
  "${attest_args[@]}" \
  --build-arg VERSION="${TAG}" \
  --build-arg COMMIT_SHA="${COMMIT_SHA}" \
  -t "${CONTROLLER_IMAGE}" \
  -f "${tmp_dockerfile}" \
  . 2>&1 | tee "${BUILD_LOG_FILE}"

echo "Asserting CVE patches were applied during nginx build (build log inspection)"
required_cve_patches=(
  "35_nginx-1.27.1-CVE-2026-40460.patch"
  "36_nginx-1.27.1-CVE-2026-40701.patch"
  "37_nginx-1.27.1-CVE-2026-42934.patch"
  "38_nginx-1.27.1-CVE-2026-42945.patch"
  "39_nginx-1.27.1-CVE-2026-42946.patch"
)
patch_missing=0
for p in "${required_cve_patches[@]}"; do
  expected_count=$(echo "${PLATFORMS}" | tr ',' '\n' | wc -l | tr -d ' ')
  actual_count=$(grep -c "Patch: ${p}" "${BUILD_LOG_FILE}" || true)
  if [[ "${actual_count}" -lt "${expected_count}" ]]; then
    echo "  MISSING: ${p} (expected >=${expected_count} apply lines, found ${actual_count})" >&2
    patch_missing=1
  else
    echo "  ok: ${p} (${actual_count} apply lines across platforms)"
  fi
done
if [[ "${patch_missing}" -ne 0 ]]; then
  echo "FAIL: one or more CVE patches were not observed in the build log; refusing to mark build as good." >&2
  exit 1
fi

for ARCH in ${ARCHES}; do
  PLATFORM="linux/${ARCH}"

  echo "Verifying nginx version for ${ARCH}"
  docker run --rm --platform "${PLATFORM}" --entrypoint /usr/bin/nginx "${CONTROLLER_IMAGE}" -V

  echo "Checking nginx module shared libraries for ${ARCH}"
  docker run --rm --platform "${PLATFORM}" --entrypoint /bin/bash "${CONTROLLER_IMAGE}" \
    -c 'ldd /etc/nginx/modules/* | grep "not found" && exit 1 || true'
done

if [[ "${PUSH}" == "true" ]]; then
  echo "Resolving published image digest"
  docker buildx imagetools inspect "${CONTROLLER_IMAGE}" | tee "${BUILD_LOG_DIR}/imagetools-${TAG}.txt"
fi

echo "Done: ${CONTROLLER_IMAGE}"
echo "Build log: ${BUILD_LOG_FILE}"
