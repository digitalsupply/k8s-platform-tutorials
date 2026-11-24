# 修正 GitLab OAuth 应用的 redirect_uri。
#
# 背景：
#   GitLab 要求 redirect_uri **逐字符精确匹配**，且是**登录后才校验**——
#   未登录用 curl 访问 /oauth/authorize 只会得到 302 到 /users/sign_in，
#   看不出问题。所以排查要靠直接查库（见 query-oauth-apps.rb）。
#
# 用法：
#   1. 先改下面的 UID 和 NEW_URI（NEW_URI 要与 Keycloak 实际发送的一致）
#   2. sudo gitlab-rails runner /path/to/fix-oauth-redirect-uri.rb
#
# 注意：
#   - 改完立即生效，无需重启 GitLab。
#   - Admin UI 有时不允许编辑回调地址，所以直接改库。

UID = "ead09e964d457039a35cdba98e67dd8cd853cc84489050594fc9ffbbb940ba96"
NEW_URI = "http://10.0.0.121:32669/realms/ceph-sso/broker/gitlab/endpoint"

ActiveRecord::Base.connection.execute(
  ActiveRecord::Base.sanitize_sql(
    ["update oauth_applications set redirect_uri = ? where uid = ?", NEW_URI, UID]
  )
)

rows = ActiveRecord::Base.connection.select_all(
  ActiveRecord::Base.sanitize_sql(
    ["select id,name,redirect_uri from oauth_applications where uid = ?", UID]
  )
).to_a
rows.each { |r| puts r.inspect }
