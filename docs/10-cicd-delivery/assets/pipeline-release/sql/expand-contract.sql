\timing on
DROP DATABASE IF EXISTS expand_contract_lab;
CREATE DATABASE expand_contract_lab;
\c expand_contract_lab
CREATE TABLE users (id int PRIMARY KEY, email text NOT NULL);
INSERT INTO users VALUES (1, 'alice@old');

-- 1) EXPAND: 只加可空列，不设默认值（PG11+ 不重写表，锁很短）
ALTER TABLE users ADD COLUMN email_new text;

-- 2) 双写：老应用继续写 email，新应用同时写 email_new
INSERT INTO users (id, email, email_new) VALUES (2, 'bob@old', 'bob@new');
-- 3) 回填历史数据（分批更稳，这里只有 1 行）
UPDATE users SET email_new = email WHERE email_new IS NULL;

-- 4) 新代码先用 coalesce 读，保证回滚安全
SELECT id, email, email_new, coalesce(email_new, email) AS read_value FROM users ORDER BY id;

-- 5) 观察期后 CONTRACT：先删旧列，再改名+非空
ALTER TABLE users DROP COLUMN email;
ALTER TABLE users RENAME COLUMN email_new TO email;
ALTER TABLE users ALTER COLUMN email SET NOT NULL;
SELECT * FROM users ORDER BY id;
\d users
