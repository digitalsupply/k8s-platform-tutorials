# 通过 gitlab-rails runner 创建 GitLab OAuth 应用（给 Keycloak 用）。
#
# 适用场景：
#   - Admin API token 权限不足（insufficient_scope）
#   - 需要指定 organization_id（GitLab 19.5 的 oauth_applications 表有
#     CHECK (organization_id IS NOT NULL)，不指定会创建失败）
#
# 用法：
#   sudo gitlab-rails runner /path/to/create-oauth-app.rb
#
# 注意：
#   - client_secret **只返回一次**，脚本写入 /tmp/keycloak_oauth.txt（权限 600）。
#     请立即转存到 K8s Secret / SealedSecret，丢失只能删掉重建。
#   - redirect_uri 必须与 Keycloak 的 KC_HOSTNAME / realm / IdP 别名一致，
#     格式：http://<Keycloak外部地址>/realms/<realm>/broker/<IdP别名>/endpoint
#     改了 KC_HOSTNAME 或 realm 名后必须同步改这里，否则登录时报
#     "The redirect URI included is not valid"。

old = Doorkeeper::Application.find_by(name: "keycloak")
old&.destroy rescue nil

org = Organizations.find_by(name: "default")
org = Organizations.create!(name: "default") if org.nil?

app = Doorkeeper::Application.create!(
  name: "keycloak",
  redirect_uri: "http://10.0.0.121:32669/realms/ceph-sso/broker/gitlab/endpoint",
  scopes: "openid profile email",
  confidential: true,
  organization_id: org.id
)

File.write(
  "/tmp/keycloak_oauth.txt",
  "client_id=#{app.uid}\nclient_secret=#{app.secret}\norg_id=#{org.id}\n"
)
puts "created: #{app.uid}"
