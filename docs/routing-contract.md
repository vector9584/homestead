# 路由约定：什么时候 200、什么时候 401、什么时候 404

这张表是这套系统的行为契约。改动 nginx 之前先看它，改完按它逐条验。

## 状态码矩阵

| 请求 | 期望 | 说明 |
|---|---|---|
| `/` | **200** | 首页，公开 |
| `/<开放目录>/` | **200** | 开放目录，不需要登录 |
| `/<受保护目录>/` 未登录 | **401** | 落到自定义 401 页 |
| `/<受保护目录>/` 已登录且有权限 | **200** | 正常 |
| `/<受保护目录>/` 已登录但无权限 | **404** | 见下方"为什么不给 403" |
| `/admin/` 未登录 | **401** | 后台 |
| `/nonexistent` | **404** | 必须 404，不能是 401 |
| `/foo/bar/baz.txt` | **404** | 同上 |
| `/assets/*.css` | **200** | 静态资源，公开 |
| `/drop/`（WebDAV `PUT`/`DELETE`） | 由 WebDAV 判定 | 写入路径不经过 `auth_request` |

## 为什么"不存在的地址"最容易做错

`auth_request` 是 **server 级**指令，它在 `try_files` **之前**执行。默认写法的执行顺序是：

```
请求 → auth_request（问：登录了吗？）→ try_files（问：文件在吗？）
```

于是：一个根本不存在的路径，也会先被要求登录。

用户看到的现象是"这个站随便敲个地址都要登录"，而不是"这个地址不存在"。这不只是体验问题——它让所有 404 都变成了 401，自定义 404 页永远没有出场机会。

### 修法：在 auth 入口里先判存在性

```php
// .acl/auth.php 的最前面
$path = realpath($_SERVER['DOCUMENT_ROOT'] . parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH));
if ($path === false) {
    // 文件/目录不存在 → 直接放行，把判断交给 try_files
    http_response_code(204);
    exit;
}
```

`204` 表示"放行，不用管我"。nginx 收到 204 就继续往下走 `try_files`，不存在自然出 404。

**注意**：这一段必须在"检查 Cookie / session"之前。放在后面就等于没放。

## 第二个坑：`try_files ... =404` 不触发 `error_page`

```nginx
location / {
    try_files $uri $uri/ =404;   # ← 这个 404 不会走 error_page
}
```

`try_files` 内部产生的 404 是**直接返回给客户端**的，不进入 nginx 的 `error_page` 处理链。所以配置里写着 `error_page 404 /404.html`，页面上还是浏览器的默认 404。

### 修法：命名 location + `return`

```nginx
location / {
    try_files $uri $uri/ @notfound;
}

location @notfound {
    return 404;          # ← 这个 404 会走 error_page
}
```

同理，`error_page` 是**内部跳转**：地址栏不变。这对 401 正好（登录完还在原地），对 404 意味着用户不知道自己在哪个地址——所以 404 页上必须给"回首页"。

## 401 与 404 的分工

一个刻意的选择：**已登录但无权限时返回 404，不是 403。**

理由是 403 会明确告诉对方"这个路径存在，只是你不能看"——这本身就是信息泄露。404 什么都不说。

代价是排查问题时容易误判成"文件没上传成功"。所以后台要有一个**只有管理员能看的目录清单**，用来区分"真的不存在"和"存在但对你不可见"。

## WebDAV 写入路径

暂存区的上传和删除走 WebDAV，**不经过 `auth_request`**：

```nginx
location /drop/ {
    dav_methods PUT DELETE;
    create_full_put_path on;
    dav_access user:rw group:r all:r;
    client_max_body_size 2g;
}
```

三条注意：

1. **`dav_methods` 需要 nginx 编译了 `--with-http_dav_module`**。系统自带的那套 nginx 常常没有——这就是为什么不能把两个 nginx 合并（详见 [JOURNEY.md](../JOURNEY.md) 第八节）。
2. `client_max_body_size` 默认只有 1M，不改的话大文件上传直接 413。
3. 页面上"删除"按钮调的是 `DELETE` 方法，如果 nginx 没开 WebDAV，按钮会静默失败——**前端要判断响应码**，不能点完就当成功了。

## 改完怎么验

别只看 `nginx -t`。它只能证明语法对，证明不了生效（详见 JOURNEY 第八节）。

```bash
# 逐个打状态码
for p in / /nonexistent /foo/bar/baz.txt /admin/ /drop/ /<受保护目录>/; do
    printf '%-22s %s\n' "$p" "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:<PORT>$p")"
done
```

再带上登录 Cookie 跑一遍，两组结果都符合上面那张矩阵，才算改对了。
