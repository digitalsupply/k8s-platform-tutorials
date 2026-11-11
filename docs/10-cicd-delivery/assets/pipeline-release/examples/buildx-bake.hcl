# buildx bake：把多镜像/多平台/缓存策略写成声明式配置
# 用法：
#   docker buildx bake -f buildx-bake.hcl --push
#   docker buildx bake -f buildx-bake.hcl --set '*.cache-from=type=local,src=/tmp/cache'
#
# 说明：
# - cache-to=type=registry 适合 CI 多节点共享；inline 只带一层、能力弱。
# - 应用镜像必须用不可变 tag（git SHA），不要 latest。
# - 基础镜像建议用 digest 固定，避免上游 tag 漂移。

variable "REGISTRY" { default = "192.168.67.202:8443" }
variable "PROJECT"  { default = "compassio" }
variable "TAG"      { default = "dev" } # CI 里用 git rev-parse HEAD 覆盖

group "default" { targets = ["backend", "frontend"] }

target "backend" {
  context    = "./backend"
  dockerfile = "Dockerfile"
  target     = "runtime"
  tags       = ["${REGISTRY}/${PROJECT}/backend:${TAG}"]
  platforms  = ["linux/amd64"]
  cache-from = ["type=registry,ref=${REGISTRY}/${PROJECT}/cache:backend"]
  cache-to   = ["type=registry,ref=${REGISTRY}/${PROJECT}/cache:backend,mode=max"]
  provenance = true
  sbom       = true
}

target "frontend" {
  context    = "./frontend"
  dockerfile = "Dockerfile"
  target     = "runtime"
  tags       = ["${REGISTRY}/${PROJECT}/frontend:${TAG}"]
  platforms  = ["linux/amd64"]
  cache-from = ["type=registry,ref=${REGISTRY}/${PROJECT}/cache:frontend"]
  cache-to   = ["type=registry,ref=${REGISTRY}/${PROJECT}/cache:frontend,mode=max"]
  provenance = true
  sbom       = true
}
