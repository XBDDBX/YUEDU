# 书源规则速查

## 选择器

| 写法 | 含义 |
|---|---|
| `class.xxx` | 按 class 取 |
| `id.xxx` | 按 id 取 |
| `tag.a` | 按标签取 |
| `text.关键词` | 按包含的文本取 |
| `children` | 取全部子元素 |
| `children.xxx` | 取 class 为 xxx 的子元素 |
| `.article > p` | 直接用 CSS 选择器 |
| `-class.ad` | 排除项（跳过） |
| `规则[0]` / `规则[-1]` | 取第 0 个 / 倒数第一个 |

## 取值动作

在规则后用 `@` 接动作：

| 动作 | 结果 |
|---|---|
| `@text` | 文本（含子元素文本） |
| `@ownText` | 只取自己的文本 |
| `@html` | innerHTML，正文推荐 |
| `@outerHtml` | 含自身标签的 HTML |
| `@href` | 链接，自动补全域名 |
| `@src` | 图片地址 |
| `@title` / `@alt` / `@value` / `@content` | 对应属性 |
| `@attr.xxx` | 任意属性 |

## 组合

| 写法 | 含义 |
|---|---|
| `规则1 \|\| 规则2` | 前一个取不到就用后一个 |
| `规则1 && 规则2` | 两段结果合并 |
| `规则##正则##替换##` | 取值后再正则替换，`$1` 引用分组 |
| `规则##正则##` | 匹配到的内容删掉 |

## JSON 接口

页面返回 JSON 时用：

```
@json:$.data.books[*].name
$.data.list[*].title
```

支持 `$` 根、`.key`、`[n]`、`[*]`。

## 典型配置

```
搜索书单：class.book-item
书名：class.title@text
详情：class.title@href
作者：class.author@text
封面：tag.img@src

目录列表：id.list@tag.a
章节名：text
章节链接：href

正文：id.content@html
下一页：class.next@href
```

## 不支持

- `@js:` JavaScript 规则
- `{{ }}` JS 模板
- XPath（`//` 开头）
- `@put` / `@get` 变量、`{{book.name}}` 之类动态变量
