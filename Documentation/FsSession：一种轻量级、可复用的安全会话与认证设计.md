FsSession：一种轻量级、可复用的安全会话与认证设计
1. 设计目标

FsSession 的目标是设计一种轻量级的应用层安全会话机制。

它不依赖 HTTPS，也不要求特定的底层传输协议。只要协议能够携带一个可选的 client_id，就可以使用同一套 FsSession 机制。

因此可以运行在：

HTTP
HTTPS
自定义 TCP
UDP 上层协议
自定义二进制协议
其他应用层协议

FsSession 的核心不是“登录 Session”，而是一个可以被不同业务共同使用的安全状态机。

注册、登录、支付、修改重要设置、匿名敏感操作等，都可以建立在 FsSession 之上。

2. 核心思想

FsSession 的核心状态可以抽象为：

FsSession = {
    client_id,
    Z,
    random,
    random_index,
    random_used,
    timeout
}

如果需要权限控制，则增加：

permission

整个安全会话围绕以下几个元素运行：

ECDH
  ↓
共享秘密 Z
  ↓
数据保护
  ↓
random
  ↓
random_index
  ↓
严格状态推进

其核心思想是：

客户端和服务器首先通过 ECDH 建立共享秘密 Z，之后所有需要保护的业务数据都依赖当前 Z，同时通过 random 和 random_index 保证请求状态只能按照预期顺序推进。

3. FsSession 数据结构

一个基本实现可以使用：

struct FsSession {
    struct FsDB_Record base;

    /* 唯一id，0-是无效值，有其他用途 */
    unsigned int id;

    /* ECDH 的 Z */
    unsigned int ECDH_z[4];

    /* 随机值，防止客户端批量生成请求 */
    unsigned short random;

    /*
     * 随机值序号：
     *
     * 0：没有完成认证
     * 1：认证中的中间状态
     * 2及以上：正常认证状态
     *
     * 正常情况下不出现0和1。
     * 每次获取新的随机值时增加。
     *
     * random_index 可以用于防止多个客户端共享同一个 Z
     * 后进行乱序请求。
     */
    unsigned short random_index : 15;

    /*
     * 产生新的 random 时置0，
     * random 被使用后置1。
     */
    unsigned int random_used : 1;

    /* 超时时间 */
    unsigned int timeout;
};

如果需要权限：

unsigned int permission;

例如：

#define FsSession_permission_login  (1 << 0)
#define FsSession_permission_pay    (1 << 1)
#define FsSession_permission_admin  (1 << 2)
4. FsSession 建立

客户端首先生成 ECDH 密钥：

a

并计算：

A = g^a

发送：

ECDH_A

服务器生成：

b

并计算：

B = g^b

双方得到：

Z = B^a = A^b

服务器创建：

FsSession {
    id = client_id
    ECDH_z = Z
    random = new_random
    random_index = 0
    random_used = 0
    timeout = ...
}

服务器返回：

random
ECDH_B

客户端根据自己的 ECDH 私钥得到相同的：

Z

此时双方已经拥有共同秘密。

第一次建立 Session 时客户端还没有 Z，因此服务器第一次返回的数据不能使用 Z 加密。

5. client_id 的作用

数据包可以抽象成：

+------------------+
|      数据头       |
+------------------+
|      数据区       |
+------------------+

数据头只需要携带：

client_id

例如：

header.client_id

服务器首先执行：

client_id
    ↓
查找 FsSession

因此 client_id 的主要作用是：

索引 FsSession，而不是作为安全秘密。

知道 client_id 并不能获得：

Z

也不能直接获得 Session 的认证权限。

6. 数据区

数据区是实际的业务数据。

例如：

{
    client_id,
    username,
    operation,
    parameter,
    hash,
    ...
}

数据区可以根据当前 FsSession 的 Z 进行加密和完整性保护。

服务器收到请求后：

client_id
    ↓
查找 FsSession
    ↓
得到 Z
    ↓
使用 Z 解码数据区
    ↓
得到完整结构化数据
    ↓
检查数据区 client_id
    ↓
检查认证信息
    ↓
进入业务接口

因此数据头中的 client_id 只是定位信息。

数据区中仍然保存真正需要验证的客户端身份信息。

7. 为什么数据区还需要 client_id

假设攻击者修改数据头：

client_id = A

改成：

client_id = B

服务器可能找到 B 对应的 FsSession。

但是攻击者无法使用 B 的 Z 正确解密原来的数据区。

即使某些情况下数据区可以被解析，也还需要验证：

数据区 client_id == 数据头 client_id

因此：

数据头 client_id
        +
数据区 client_id

形成两层一致性检查。

8. random

random 是服务器每轮产生的随机值。

典型状态：

产生 random
    ↓
random_used = 0
    ↓
返回客户端
    ↓
客户端使用 random
    ↓
服务器验证
    ↓
random_used = 1
    ↓
生成新的 random
    ↓
random_used = 0

客户端可以计算：

H(random : random_index : Z)

作为当前请求的一部分认证数据。

这样一个已经消费的 random 不应该被无限重复使用。

9. random_index

random_index 不是秘密。

它的主要作用是维护请求状态的顺序。

例如：

random_index = 10

服务器成功处理一次后：

10 → 11

下一次必须使用：

11

而不能再次使用：

10

因此：

S10
 ↓
S11
 ↓
S12
 ↓
S13

而不是：

S10
 ↓
S12

或者：

S10
 ↓
S10
10. 防止多个客户端共享 Z

假设某个原因导致：

客户端 A
客户端 B

获得了相同的：

Z

如果只有 Z，没有状态序号，那么两个客户端可能共享同一个安全状态。

random_index 可以使服务器维护：

I0 → I1 → I2 → I3 → ...

客户端不能简单地把已经使用过的认证数据拿到另一个客户端继续使用。

因此 random_index 的作用主要是：

状态隔离和顺序控制，而不是增加 Z 的密码学强度。

11. FsSession 不允许关键请求并发

FsSession 的设计可以明确规定：

同一个 FsSession 的关键请求必须严格串行。

例如：

请求1
 ↓
服务器返回新状态
 ↓
请求2
 ↓
服务器返回新状态
 ↓
请求3

而不允许：

请求1 ──────┐
             ├→ 同时修改 FsSession
请求2 ──────┘

如果客户端对同一个 Session 进行关键数据并发操作，可以直接视为异常状态。

服务器端即使是多进程，也必须保证状态转换具有原子性。

核心要求是：

验证旧状态
+
执行状态转换
+
保存新状态

不能让两个进程同时成功消费同一个状态。

12. 普通 FsSession 请求

当数据头中存在 client_id：

客户端
  |
  | client_id + 数据区
  ↓
服务器

服务器执行：

1. 使用 client_id 查找 FsSession
2. 获取 Z
3. 使用 Z 解码数据区
4. 验证数据区完整性
5. 验证数据区 client_id
6. 验证 random
7. 验证 random_index
8. 验证 random_used
9. 进入业务接口
10. 更新 random
11. 更新 random_index
12. 更新 timeout

成功后生成新的 random。

13. 无 client_id 的请求

当数据头中没有 client_id 时，可以走未建立 Session 的路径。

例如：

客户端
  ↓
无 client_id
  ↓
建立 FsSession
  ↓
ECDH_A
  ↓
服务器
  ↓
ECDH_B
  +
random

第一次建立 Session 时：

客户端没有 Z

所以服务器不能使用 Z 加密第一次返回的数据。

第一次握手的数据可以是明文，但它只是用于建立后续安全状态。

14. 明文模式

FsSession 并不要求所有请求都必须加密。

例如数据头中没有 client_id：

无 client_id
    ↓
明文数据
    ↓
业务处理

这可以用于：

调试
公开接口
匿名访问
建立 Session
不需要机密性的接口

如果数据头存在 client_id：

client_id
    ↓
FsSession
    ↓
Z
    ↓
保护数据区

因此是否启用安全 Session，可以由协议头决定。

但是：

对于明确要求认证的接口，不能因为删除 client_id 就自动降级成无需认证的接口。

业务接口必须明确规定自己的安全要求。

15. 注册

注册也可以使用 FsSession。

客户端首先建立：

ECDH
 ↓
Z
 ↓
FsSession

然后通过 FsSession 发送：

username
password
其他注册信息

密码等敏感数据进入受保护的数据区。

因此不需要单独设计：

注册安全协议

注册本身只是一个使用 FsSession 的业务接口。

16. 登录

登录也可以直接建立在 FsSession 上。

初始状态：

random_index = 0

客户端使用当前 FsSession：

Z0

向服务器发送：

username
ECDH_A
hash(...)

服务器完成标准 FsSession 验证后，将数据提交给登录接口。

登录接口根据用户名获得密码相关信息。

然后进行一次新的 ECDH 参数交换。

服务器产生：

ECDH_B

并让密码参与 ECDH 参数的变换。

例如抽象表示：

B' = B · f(password)

服务器返回：

B'

客户端拥有密码，因此可以：

B' / f(password)

得到：

B

然后重新计算：

Z1

服务器也能够得到对应的：

Z1

于是：

Z0
 ↓
密码认证
 ↓
Z1

完成一次密码认证。

17. 登录后的 random

认证成功后：

random_used = 1

客户端继续按照普通 FsSession 流程获取新的 random。

如果能够成功获得新的 random：

random_index:
0 → 1

则说明密码认证成功。

随后可以进入正常认证状态。

18. random_index 的状态定义

可以定义：

0：未认证
1：认证中间状态
2及以上：已经认证

因此：

0
 ↓
密码认证
 ↓
1
 ↓
获取新的 random
 ↓
2

之后正常运行：

2
 ↓
3
 ↓
4
 ↓
5
...

正常运行过程中不再出现：

0
1
19. 支付重新认证

支付属于高风险操作，可以再次要求密码认证。

例如：

当前：

Z1
random_index = 20

支付接口要求重新认证：

Z1
 ↓
密码认证
 ↓
Z2

认证成功后：

获取新的 random
 ↓
random_index = 21
 ↓
支付接口

因此不需要另外设计：

支付密码 Session
支付 Token
支付二次认证 Token

支付只是再次执行 FsSession 的认证流程。

20. 多次认证

FsSession 可以重复认证。

例如：

建立 Session：

Z0

登录：

Z0 → Z1

支付：

Z1 → Z2

修改重要设置：

Z2 → Z3

管理员操作：

Z3 → Z4

因此认证本质上是：

验证某种凭据
    ↓
修改当前安全状态
    ↓
产生新的 Z

而不是：

登录认证协议
支付认证协议
管理员认证协议

每一种业务都可以复用同一个安全基础。

21. 权限

FsSession 可以记录：

unsigned int permission;

例如：

#define FsSession_permission_login  (1 << 0)
#define FsSession_permission_pay    (1 << 1)
#define FsSession_permission_admin  (1 << 2)

登录成功：

permission |= login

支付重新认证成功：

permission |= pay

业务接口只需要检查：

permission

这样认证逻辑和业务逻辑可以分离。

22. Z 的作用

Z 是 FsSession 最核心的秘密。

当前状态：

Z0

用于保护当前数据。

认证成功后：

Z0 → Z1

旧的 Z 不再作为当前 Session 的秘密。

如果需要密钥更新，应通过新的 ECDH 或标准 KDF 产生新的密码学密钥。

不应该简单认为：

Z_new = Z + 1

就等价于密码学意义上的密钥更新。

random_index 可以作为状态计数器，但不应该代替密码学密钥更新。

23. Z 的长度

如果：

unsigned int ECDH_z[4];

则 Z 为：

128 bit

128 bit 的随机密码学秘密具有非常高的暴力破解门槛。

但是实际实现中更推荐：

ECDH
 ↓
共享秘密 Z
 ↓
KDF / HKDF
 ↓
实际加密密钥

而不是直接把原始 Z 当作所有密码学操作的密钥。

例如：

K = HKDF(Z, context)

然后根据用途产生：

K_enc
K_auth

等不同密钥。

24. 数据区必须具有完整性保护

单纯加密并不能防止攻击者修改密文。

因此数据区需要同时具备：

机密性
+
完整性

即：

攻击者无法读取
+
攻击者无法修改

实际实现应该使用成熟的 AEAD 或等价的标准认证加密方案。

抽象表示：

C = AEAD_Encrypt(
        key,
        nonce,
        plaintext,
        associated_data
    )

解密：

plaintext = AEAD_Decrypt(...)

如果数据被修改：

AEAD_Decrypt → failure

而不是得到一个可以继续反序列化的错误数据。

25. 序列化与完整性

FsSession 的数据区可以使用结构化序列化方式。

例如：

数据区
├── client_id
├── operation
├── parameter
├── random
├── random_index
├── hash
└── ...

序列化格式本身可以具有严格的结构检查。

但是：

序列化格式的校验不能代替密码学完整性保护。

结构校验只能防止：

格式错误
长度错误
字段错误

而不能保证：

攻击者没有修改合法数据

因此真正的安全数据区应该同时使用：

严格序列化
+
密码学完整性保护
26. FsSession 与 HTTPS/TLS

FsSession 和 HTTPS/TLS 的设计目标不同。

TLS 是通用的安全传输协议，负责：

密钥交换
服务器身份认证
握手完整性
数据加密
数据完整性
密钥更新
防止握手被篡改
标准密码套件
记录层保护

FsSession 更偏向：

应用层的轻量级安全 Session 与认证状态机。

FsSession 不要求：

域名
CA 证书
HTTPS
HTTP
长连接
Cookie
JWT
特定传输协议

只需要：

client_id
+
数据区

就可以运行。

27. FsSession 与 TLS 的一个重要区别

TLS 的一个重要能力是：

服务器身份认证

也就是说客户端可以判断：

“我连接的服务器是不是我想连接的那个服务器？”

FsSession 如果只使用：

ECDH

本身并不能自动提供服务器身份认证。

因此 FsSession 可以提供：

安全数据传输
+
会话认证
+
业务认证

但如果应用需要防止：

假服务器

则仍然需要另外解决服务器身份认证问题。

例如可以使用：

预置公钥
证书
签名
公钥指纹
应用内固定密钥

等方式。

这与“是否使用 HTTPS”是两个不同问题。

28. FsSession 的核心状态机

可以把整个系统抽象成：

          ECDH
            │
            ↓
           Z0
            │
            ↓
        FsSession
            │
     ┌──────┼──────┐
     │      │      │
    注册    登录    匿名业务
            │
            ↓
           Z1
            │
     ┌──────┼──────┐
     │      │      │
    普通    支付    设置
    请求    认证    认证
            │
            ↓
           Z2

所有业务最终都可以归结为：

当前状态
   ↓
验证
   ↓
业务
   ↓
产生下一状态
29. 状态转换

最核心的抽象是：

S_n → S_(n+1)

其中：

S = {
    Z,
    random,
    random_index,
    random_used,
    permission,
    timeout
}

普通请求：

S_n
 ↓
验证
 ↓
S_(n+1)

登录：

S_n
 ↓
密码认证
 ↓
Z_new
 ↓
S_(n+1)

支付认证：

S_n
 ↓
密码认证
 ↓
Z_new
 ↓
S_(n+1)

因此：

FsSession 本质上是一个安全状态转换系统。

30. 多进程实现

FsSession 可以由底层：

FsDB_Record

提供增删改查能力。

多个进程可以共同访问 FsSession。

但关键状态必须具有原子状态转换能力。

例如：

读取 S_n
 ↓
验证 S_n
 ↓
修改为 S_(n+1)

不能出现：

进程 A：读取 S_n
进程 B：读取 S_n

进程 A：验证成功
进程 B：验证成功

进程 A：更新
进程 B：更新

否则同一个 random 可能被重复消费。

因此数据库层必须提供：

锁

或者：

CAS
原子更新
事务

等机制。

31. 超时

FsSession 保存：

unsigned int timeout;

系统存在基准时间：

time0

Session 有效条件：

timeout + time0 > current_time

否则：

删除 FsSession

这样可以避免服务器永久保存无效 Session。

32. 错误处理

FsSession 的错误处理可以统一。

例如：

client_id 不存在
        ↓
错误
Z 解密失败
        ↓
错误
数据区 client_id 不一致
        ↓
错误
random 错误
        ↓
错误
random_index 错误
        ↓
错误
random_used 状态错误
        ↓
错误

严重错误可以：

删除 FsSession

然后使用非加密方式返回错误。

这样客户端不会因为错误状态而一直保留一个已经失效的 Session。

33. 调试能力

FsSession 不要求所有通信都强制加密。

例如：

没有 client_id

可以允许：

明文请求
+
明文响应

这样可以方便调试协议。

而正式安全请求：

client_id
+
FsSession
+
Z

则进入安全数据路径。

因此可以同时兼顾：

安全模式

和：

调试模式

但正式环境中是否允许明文路径应该由业务策略明确控制。

34. 协议无关

FsSession 不规定：

HTTP Header
Cookie
URL
TCP Packet

具体格式。

它只要求协议能够表达：

client_id

以及：

数据区

例如 HTTP：

GET /api?client_id=123

也可以。

自定义 TCP：

+----------+
| client_id|
+----------+
| payload  |
+----------+

也可以。

甚至可以让：

HTTP
TCP
Unix Socket
其他协议

共享同一个 FsSession 数据库。

因此 FsSession 是：

协议无关的应用层安全状态。

35. 注册、登录、支付统一

传统系统可能设计成：

注册
 └── 注册认证

登录
 └── 登录认证

支付
 └── 支付认证

修改密码
 └── 二次认证

FsSession 可以统一成：

              FsSession
                  │
       ┌──────────┼──────────┐
       │          │          │
      注册        登录       支付
       │          │          │
       └──────────┼──────────┘
                  │
             状态转换
                  │
               Z_new

业务只是不同的状态转换。

36. FsSession 的设计特点

FsSession 的核心特点可以总结为：

轻量

核心状态非常小：

id
Z
random
random_index
random_used
timeout
协议无关

不绑定：

HTTP
HTTPS
TCP
会话统一

注册、登录、支付、重新认证都可以复用。

状态明确

每个请求都对应明确的：

random
random_index
Z
支持重新认证

任何高风险业务都可以要求：

重新认证
支持多进程

底层数据结构可以由统一数据库层管理。

可以支持调试

可以存在明确的非加密模式。

37. 安全边界

FsSession 可以解决：

共享秘密建立
+
数据机密性
+
数据完整性
+
请求状态
+
业务认证
+
重新认证
+
权限状态

但是它不能自动解决所有安全问题。

特别需要单独考虑：

服务器身份认证

以及：

随机数生成
ECDH 参数验证
AEAD nonce 管理
密钥派生
重放保护
状态原子更新
密码存储
密码认证协议

这些部分必须使用经过验证的密码学设计。

38. 最终抽象

FsSession 可以最终抽象成：

             ECDH
               ↓
              Z
               ↓
        ┌──────────────┐
        │  FsSession   │
        │              │
        │ ID           │
        │ Z            │
        │ random       │
        │ random_index │
        │ random_used  │
        │ permission   │
        │ timeout      │
        └──────┬───────┘
               │
               ↓
          安全数据区
               │
       ┌───────┼────────┐
       ↓       ↓        ↓
      注册     登录      支付
       │       │        │
       └───────┼────────┘
               ↓
          状态重新生成
               ↓
              Z'

核心状态始终按照：

S0 → S1 → S2 → S3 → ...

推进。

39. 核心理念

FsSession 并不试图把每一个业务都设计成一个独立的安全协议。

它把安全能力抽象成一个统一的状态对象：

FsSession

然后让业务只负责：

需要什么权限
需要什么认证
认证成功后如何改变状态

因此：

登录

不是特殊的 Session。

支付

也不是特殊的 Session。

注册

同样不是特殊的 Session。

它们都是：

FsSession 上的状态转换

最终整个设计可以浓缩为：

ECDH
  ↓
建立 Z
  ↓
FsSession
  ↓
random + random_index
  ↓
严格状态推进
  ↓
业务认证
  ↓
Z 更新
  ↓
继续使用同一个 FsSession

其核心目标就是：

用一个很小、协议无关、可复用的安全状态结构，把会话、请求认证、重新认证、权限和业务安全统一起来。