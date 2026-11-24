# 查询 GitLab 上所有 OAuth 应用（含 redirect_uri / scopes / confidential）。
#
# 用法：
#   sudo gitlab-rails runner /path/to/query-oauth-apps.rb
#
# 说明：
#   - GitLab 19.5 没有 OAuthApplication 这个模型常量（会报
#     uninitialized constant OAuthApplication），直接用 SQL 查。
#   - 查 redirect_uri 是排查「The redirect URI included is not valid」的
#     第一步：对比 GitLab 里注册的值与 Keycloak 实际发送的值。

rows = ActiveRecord::Base.connection.select_all(
  "select id,name,uid,redirect_uri,scopes,confidential from oauth_applications"
).to_a
rows.each { |r| puts r.inspect }
