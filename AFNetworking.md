# AFNetworking源码解析
除去Support Files，可以看到AF分为如下5个功能模块：

-   网络通信模块(AFURLSessionManager、AFHTTPSessionManger)
-   网络状态监听模块(Reachability)
-   网络通信安全策略模块(Security)
-   网络通信信息序列化/反序列化模块(Serialization)
-   对于iOS UIKit库的扩展(UIKit)

###### 其核心当然是网络通信模块AFURLSessionManager。大家都知道，AF3.x是基于NSURLSession来封装的。所以这个类围绕着NSURLSession做了一系列的封装。而其余的四个模块，均是为了配合网络通信或对已有UIKit的一个扩展工具包。

这五个模块所对应的类的结构关系图如下所示：

![image.jpeg](https://p1-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/6c2a9cc5db8449e0a956081c09d3639a~tplv-k3u1fbpfcp-watermark.image?)

  其中AFHTTPSessionManager是继承于AFURLSessionManager的，我们一般做网络请求都是用这个类，**但是它本身是没有做实事的，只是做了一些简单的封装，把请求逻辑分发给父类AFURLSessionManager或者其它类去做。**

###### 首先我们简单的写个get请求：

**

```
AFHTTPSessionManager *manager = [[AFHTTPSessionManager alloc]init];

[manager GET:@"http://localhost" parameters:nil progress:nil success:^(NSURLSessionDataTask * _Nonnull task, id  _Nullable responseObject) {
 
} failure:^(NSURLSessionDataTask * _Nullable task, NSError * _Nonnull error) {
    
}];
```

首先我们我们调用了初始化方法生成了一个manager，我们点进去看看初始化做了什么:

**

```
- (instancetype)init {
    return [self initWithBaseURL:nil];
}

- (instancetype)initWithBaseURL:(NSURL *)url {
    return [self initWithBaseURL:url sessionConfiguration:nil];
}

- (instancetype)initWithSessionConfiguration:(NSURLSessionConfiguration *)configuration {
    return [self initWithBaseURL:nil sessionConfiguration:configuration];
}

- (instancetype)initWithBaseURL:(NSURL *)url
           sessionConfiguration:(NSURLSessionConfiguration *)configuration
{
    self = [super initWithSessionConfiguration:configuration];
    if (!self) {
        return nil;
    }
    //对传过来的BaseUrl进行处理，如果有值且最后不包含/，url加上"/"
  //--经一位热心读者更正...以后注释也一定要走心啊...不能误导大家...
    if ([[url path] length] > 0 && ![[url absoluteString] hasSuffix:@"/"]) {
        url = [url URLByAppendingPathComponent:@""];
    }

    self.baseURL = url;

    self.requestSerializer = [AFHTTPRequestSerializer serializer];
    self.responseSerializer = [AFJSONResponseSerializer serializer];

    return self;
}
```

-   初始化都调用到`- (instancetype)initWithBaseURL:(NSURL *)url sessionConfiguration:(NSURLSessionConfiguration *)configuration`方法中来了。
-   **其实初始化方法都调用父类的初始化方法。** 父类也就是AF3.x**最最核心的类AFURLSessionManager**。几乎所有的类都是围绕着这个类在处理业务逻辑。
-   除此之外，方法中把baseURL存了起来，还生成了一个请求序列对象和一个响应序列对象。后面再细说这两个类是干什么用的。

直接来到父类AFURLSessionManager的初始化方法：

**

```
- (instancetype)init {
    return [self initWithSessionConfiguration:nil];
}

- (instancetype)initWithSessionConfiguration:(NSURLSessionConfiguration *)configuration {
    self = [super init];
    if (!self) {
        return nil;
    }
    if (!configuration) {
        configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    }
    self.sessionConfiguration = configuration;
    self.operationQueue = [[NSOperationQueue alloc] init];
    //queue并发线程数设置为1
    self.operationQueue.maxConcurrentOperationCount = 1;
    
    //注意代理，代理的继承，实际上NSURLSession去判断了，你实现了哪个方法会去调用，包括子代理的方法！
    self.session = [NSURLSession sessionWithConfiguration:self.sessionConfiguration delegate:self delegateQueue:self.operationQueue];
    
    //各种响应转码
    self.responseSerializer = [AFJSONResponseSerializer serializer];

    //设置默认安全策略
    self.securityPolicy = [AFSecurityPolicy defaultPolicy];

#if !TARGET_OS_WATCH
    self.reachabilityManager = [AFNetworkReachabilityManager sharedManager];
#endif
    // 设置存储NSURL task与AFURLSessionManagerTaskDelegate的词典（重点，在AFNet中，每一个task都会被匹配一个AFURLSessionManagerTaskDelegate 来做task的delegate事件处理） ===============
    self.mutableTaskDelegatesKeyedByTaskIdentifier = [[NSMutableDictionary alloc] init];

    //  设置AFURLSessionManagerTaskDelegate 词典的锁，确保词典在多线程访问时的线程安全
    self.lock = [[NSLock alloc] init];
    self.lock.name = AFURLSessionManagerLockName;

    // 置空task关联的代理
    [self.session getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) {        
        for (NSURLSessionDataTask *task in dataTasks) {
            [self addDelegateForDataTask:task uploadProgress:nil downloadProgress:nil completionHandler:nil];
        }
        for (NSURLSessionUploadTask *uploadTask in uploadTasks) {
            [self addDelegateForUploadTask:uploadTask progress:nil completionHandler:nil];
        }
        for (NSURLSessionDownloadTask *downloadTask in downloadTasks) {
            [self addDelegateForDownloadTask:downloadTask progress:nil destination:nil completionHandler:nil];
        }
    }];
    return self;
}
```

-   这个就是最终的初始化方法了，注释应该写的很清楚，唯一需要说的就是三点：

    -   `self.operationQueue.maxConcurrentOperationCount = 1;`**这个operationQueue就是我们代理回调的queue。这里把代理回调的线程并发数设置为1了。** 至于这里为什么要这么做，我们先留一个坑，等我们讲完AF2.x之后再来分析这一块。
    -   第二就是我们初始化了一些属性，其中包括`self.mutableTaskDelegatesKeyedByTaskIdentifier`，这个是用来让每一个请求task和我们自定义的AF代理来建立映射用的，其实AF对task的代理进行了一个封装，并且转发代理到AF自定义的代理，这是AF比较重要的一部分，接下来我们会具体讲这一块。
    -   第三就是下面这个方法：

```
[self.session getTasksWithCompletionHandler:^(NSArray *dataTasks, NSArray *uploadTasks, NSArray *downloadTasks) { 
}];
```

首先说说这个方法是干什么用的：这个方法用来异步的获取当前session的所有未完成的task。其实讲道理来说在初始化中调用这个方法应该里面一个task都不会有。我们打断点去看，也确实如此，里面的数组都是空的。  
但是想想也知道，AF大神不会把一段没用的代码放在这吧。辗转多处，终于从AF的issue中找到了结论：[github ](https://link.jianshu.com/?t=https://github.com/AFNetworking/AFNetworking/issues/3499)。

-   原来这是为了防止后台回来，重新初始化这个session，一些之前的后台请求任务，导致程序的crash。

初始化方法到这就全部完成了。

接着我们来看看网络请求:

```
- (NSURLSessionDataTask *)GET:(NSString *)URLString
                   parameters:(id)parameters
                     progress:(void (^)(NSProgress * _Nonnull))downloadProgress
                      success:(void (^)(NSURLSessionDataTask * _Nonnull, id _Nullable))success
                      failure:(void (^)(NSURLSessionDataTask * _Nullable, NSError * _Nonnull))failure
{
     //生成一个task
    NSURLSessionDataTask *dataTask = [self dataTaskWithHTTPMethod:@"GET"
                                                        URLString:URLString
                                                       parameters:parameters
                                                   uploadProgress:nil
                                                 downloadProgress:downloadProgress
                                                          success:success
                                                          failure:failure];
  
    //开始网络请求
    [dataTask resume];

    return dataTask;
}
```

方法走到类AFHTTPSessionManager中来，调用父类，也就是我们整个AF3.x的核心类AFURLSessionManager的方法，生成了一个系统的NSURLSessionDataTask实例，并且开始网络请求。  
我们继续往父类里看，看看这个方法到底做了什么：

```
- (NSURLSessionDataTask *)dataTaskWithHTTPMethod:(NSString *)method
                                       URLString:(NSString *)URLString
                                      parameters:(id)parameters
                                  uploadProgress:(nullable void (^)(NSProgress *uploadProgress)) uploadProgress
                                downloadProgress:(nullable void (^)(NSProgress *downloadProgress)) downloadProgress
                                         success:(void (^)(NSURLSessionDataTask *, id))success
                                         failure:(void (^)(NSURLSessionDataTask *, NSError *))failure
{
    
    NSError *serializationError = nil;
    
    //把参数，还有各种东西转化为一个request
    NSMutableURLRequest *request = [self.requestSerializer requestWithMethod:method URLString:[[NSURL URLWithString:URLString relativeToURL:self.baseURL] absoluteString] parameters:parameters error:&serializationError];
    
    if (serializationError) {
        if (failure) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wgnu"
            //如果解析错误，直接返回
            dispatch_async(self.completionQueue ?: dispatch_get_main_queue(), ^{
                failure(nil, serializationError);
            });
#pragma clang diagnostic pop
        }

        return nil;
    }
    __block NSURLSessionDataTask *dataTask = nil;
    dataTask = [self dataTaskWithRequest:request
                          uploadProgress:uploadProgress
                        downloadProgress:downloadProgress
                       completionHandler:^(NSURLResponse * __unused response, id responseObject, NSError *error) {
        if (error) {
            if (failure) {
                failure(dataTask, error);
            }
        } else {
            if (success) {
                success(dataTask, responseObject);
            }
        }
    }];

    return dataTask;
}
```

-   这个方法做了两件事：  
    1.用self.requestSerializer和各种参数去获取了一个我们最终请求网络需要的NSMutableURLRequest实例。  
    2.调用另外一个方法dataTaskWithRequest去拿到我们最终需要的NSURLSessionDataTask实例，并且在完成的回调里，调用我们传过来的成功和失败的回调。
    -   注意下面这个方法，我们常用来 push pop搭配，来忽略一些编译器的警告：

```
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wgnu"
#pragma clang diagnostic pop
```

这里是用来忽略 **：？** 带来的警告，具体的各种编译器警告描述，可以参考这篇：[各种编译器的警告](https://link.jianshu.com/?t=http://fuckingclangwarnings.com/#semantic)。

-   说到底这个方法还是没有做实事，我们继续到requestSerializer方法里去看，看看AF到底如何拼接成我们需要的request的：

接着我们跑到AFURLRequestSerialization类中：

**

```
- (NSMutableURLRequest *)requestWithMethod:(NSString *)method
                                 URLString:(NSString *)URLString
                                parameters:(id)parameters
                                     error:(NSError *__autoreleasing *)error
{
    //断言，debug模式下，如果缺少改参数，crash
    NSParameterAssert(method);
    NSParameterAssert(URLString);

    NSURL *url = [NSURL URLWithString:URLString];

    NSParameterAssert(url);

    NSMutableURLRequest *mutableRequest = [[NSMutableURLRequest alloc] initWithURL:url];
    mutableRequest.HTTPMethod = method;

    //将request的各种属性循环遍历
    for (NSString *keyPath in AFHTTPRequestSerializerObservedKeyPaths()) {
        //如果自己观察到的发生变化的属性，在这些方法里
        if ([self.mutableObservedChangedKeyPaths containsObject:keyPath]) {
           //把给自己设置的属性给request设置
            [mutableRequest setValue:[self valueForKeyPath:keyPath] forKey:keyPath];
        }
    }
    //将传入的parameters进行编码，并添加到request中
    mutableRequest = [[self requestBySerializingRequest:mutableRequest withParameters:parameters error:error] mutableCopy];

    return mutableRequest;
}
```

-   讲一下这个方法，这个方法做了3件事：  
    1）设置request的请求类型，get,post,put...等  
    2）往request里添加一些参数设置，其中`AFHTTPRequestSerializerObservedKeyPaths()`是一个c函数，返回一个数组，我们来看看这个函数:
```
static NSArray * AFHTTPRequestSerializerObservedKeyPaths() {
    static NSArray *_AFHTTPRequestSerializerObservedKeyPaths = nil;
    static dispatch_once_t onceToken;
    // 此处需要observer的keypath为allowsCellularAccess、cachePolicy、HTTPShouldHandleCookies
    // HTTPShouldUsePipelining、networkServiceType、timeoutInterval
    dispatch_once(&onceToken, ^{
        _AFHTTPRequestSerializerObservedKeyPaths = @[NSStringFromSelector(@selector(allowsCellularAccess)), NSStringFromSelector(@selector(cachePolicy)), NSStringFromSelector(@selector(HTTPShouldHandleCookies)), NSStringFromSelector(@selector(HTTPShouldUsePipelining)), NSStringFromSelector(@selector(networkServiceType)), NSStringFromSelector(@selector(timeoutInterval))];
    });
    //就是一个数组里装了很多方法的名字,
    return _AFHTTPRequestSerializerObservedKeyPaths;
}
```
  其实这个函数就是封装了一些属性的名字，这些都是NSUrlRequest的属性。  
再来看看`self.mutableObservedChangedKeyPaths`,这个是当前类的一个属性：

**

```
@property (readwrite, nonatomic, strong) NSMutableSet *mutableObservedChangedKeyPaths;
```

在-init方法对这个集合进行了初始化，**并且对当前类的和NSUrlRequest相关的那些属性添加了KVO监听**：

```
 //每次都会重置变化
    self.mutableObservedChangedKeyPaths = [NSMutableSet set];
    
    //给这自己些方法添加观察者为自己，就是request的各种属性，set方法
    for (NSString *keyPath in AFHTTPRequestSerializerObservedKeyPaths()) {
        if ([self respondsToSelector:NSSelectorFromString(keyPath)]) {
            [self addObserver:self forKeyPath:keyPath options:NSKeyValueObservingOptionNew context:AFHTTPRequestSerializerObserverContext];
        }
    }
```

KVO触发的方法：

```
-(void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(__unused id)object
                        change:(NSDictionary *)change
                       context:(void *)context
{
    //当观察到这些set方法被调用了，而且不为Null就会添加到集合里，否则移除
    if (context == AFHTTPRequestSerializerObserverContext) {
        if ([change[NSKeyValueChangeNewKey] isEqual:[NSNull null]]) {
            [self.mutableObservedChangedKeyPaths removeObject:keyPath];
        } else {
            [self.mutableObservedChangedKeyPaths addObject:keyPath];
        }
    }
}
```

至此我们知道`self.mutableObservedChangedKeyPaths`其实就是我们自己设置的request属性值的集合。  
接下来调用：

```
[mutableRequest setValue:[self valueForKeyPath:keyPath] forKey:keyPath];
```

用KVC的方式，把属性值都设置到我们请求的request中去。

3）把需要传递的参数进行编码，并且设置到request中去：

```
//将传入的parameters进行编码，并添加到request中
mutableRequest = [[self requestBySerializingRequest:mutableRequest withParameters:parameters error:error] mutableCopy];
```

```
 - (NSURLRequest *)requestBySerializingRequest:(NSURLRequest *)request
                               withParameters:(id)parameters
                                        error:(NSError *__autoreleasing *)error
{
    NSParameterAssert(request);

    NSMutableURLRequest *mutableRequest = [request mutableCopy];

    //从自己的head里去遍历，如果有值则设置给request的head
    [self.HTTPRequestHeaders enumerateKeysAndObjectsUsingBlock:^(id field, id value, BOOL * __unused stop) {
        if (![request valueForHTTPHeaderField:field]) {
            [mutableRequest setValue:value forHTTPHeaderField:field];
        }
    }];

    //来把各种类型的参数，array dic set转化成字符串，给request
    NSString *query = nil;
    if (parameters) {
        //自定义的解析方式
        if (self.queryStringSerialization) {
            NSError *serializationError;
            query = self.queryStringSerialization(request, parameters, &serializationError);

            if (serializationError) {
                if (error) {
                    *error = serializationError;
                }

                return nil;
            }
        } else {
            //默认解析方式
            switch (self.queryStringSerializationStyle) {
                case AFHTTPRequestQueryStringDefaultStyle:
                    query = AFQueryStringFromParameters(parameters);
                    break;
            }
        }
    }

    //最后判断该request中是否包含了GET、HEAD、DELETE（都包含在HTTPMethodsEncodingParametersInURI）。因为这几个method的quey是拼接到url后面的。而POST、PUT是把query拼接到http body中的。
    if ([self.HTTPMethodsEncodingParametersInURI containsObject:[[request HTTPMethod] uppercaseString]]) {
        if (query && query.length > 0) {
            mutableRequest.URL = [NSURL URLWithString:[[mutableRequest.URL absoluteString] stringByAppendingFormat:mutableRequest.URL.query ? @"&%@" : @"?%@", query]];
        }
    } else {
        //post put请求
        
        // #2864: an empty string is a valid x-www-form-urlencoded payload
        if (!query) {
            query = @"";
        }
        if (![mutableRequest valueForHTTPHeaderField:@"Content-Type"]) {
            [mutableRequest setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
        }
        //设置请求体
        [mutableRequest setHTTPBody:[query dataUsingEncoding:self.stringEncoding]];
    }

    return mutableRequest;
}
```

这个方法做了3件事：  
1.从`self.HTTPRequestHeaders`中拿到设置的参数，赋值要请求的request里去  
2.把请求网络的参数，从array dic set这些容器类型转换为字符串，具体转码方式，我们可以使用自定义的方式，也可以用AF默认的转码方式。自定义的方式没什么好说的，想怎么去解析由你自己来决定。我们可以来看看默认的方式：
```
NSString * AFQueryStringFromParameters(NSDictionary *parameters) {
    NSMutableArray *mutablePairs = [NSMutableArray array];
    
    //把参数给AFQueryStringPairsFromDictionary，拿到AF的一个类型的数据就一个key，value对象，在URLEncodedStringValue拼接keyValue，一个加到数组里
    for (AFQueryStringPair *pair in AFQueryStringPairsFromDictionary(parameters)) {
        [mutablePairs addObject:[pair URLEncodedStringValue]];
    }

    //拆分数组返回参数字符串
    return [mutablePairs componentsJoinedByString:@"&"];
}
NSArray * AFQueryStringPairsFromDictionary(NSDictionary *dictionary) {
    //往下调用
    return AFQueryStringPairsFromKeyAndValue(nil, dictionary);
}
NSArray * AFQueryStringPairsFromKeyAndValue(NSString *key, id value) {
    NSMutableArray *mutableQueryStringComponents = [NSMutableArray array];

    // 根据需要排列的对象的description来进行升序排列，并且selector使用的是compare:
    // 因为对象的description返回的是NSString，所以此处compare:使用的是NSString的compare函数
    // 即@[@"foo", @"bar", @"bae"] ----> @[@"bae", @"bar",@"foo"]
    NSSortDescriptor *sortDescriptor = [NSSortDescriptor sortDescriptorWithKey:@"description" ascending:YES selector:@selector(compare:)];

    //判断vaLue是什么类型的，然后去递归调用自己，直到解析的是除了array dic set以外的元素，然后把得到的参数数组返回。
    if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dictionary = value;
        // Sort dictionary keys to ensure consistent ordering in query string, which is important when deserializing potentially ambiguous sequences, such as an array of dictionaries
        
        //拿到
        for (id nestedKey in [dictionary.allKeys sortedArrayUsingDescriptors:@[ sortDescriptor ]]) {
            id nestedValue = dictionary[nestedKey];
            if (nestedValue) {
                [mutableQueryStringComponents addObjectsFromArray:AFQueryStringPairsFromKeyAndValue((key ? [NSString stringWithFormat:@"%@[%@]", key, nestedKey] : nestedKey), nestedValue)];
            }
        }
    } else if ([value isKindOfClass:[NSArray class]]) {
        NSArray *array = value;
        for (id nestedValue in array) {
            [mutableQueryStringComponents addObjectsFromArray:AFQueryStringPairsFromKeyAndValue([NSString stringWithFormat:@"%@[]", key], nestedValue)];
        }
    } else if ([value isKindOfClass:[NSSet class]]) {
        NSSet *set = value;
        for (id obj in [set sortedArrayUsingDescriptors:@[ sortDescriptor ]]) {
            [mutableQueryStringComponents addObjectsFromArray:AFQueryStringPairsFromKeyAndValue(key, obj)];
        }
    } else {
        [mutableQueryStringComponents addObject:[[AFQueryStringPair alloc] initWithField:key value:value]];
    }

    return mutableQueryStringComponents;
}
```
-   转码主要是以上三个函数，配合着注释应该也很好理解：主要是在递归调用`AFQueryStringPairsFromKeyAndValue`。判断vaLue是什么类型的，然后去递归调用自己，直到解析的是除了array dic set以外的元素，然后把得到的参数数组返回。
-   其中有个`AFQueryStringPair`对象，其只有两个属性和两个方法：

**

```
@property (readwrite, nonatomic, strong) id field;
@property (readwrite, nonatomic, strong) id value;
   
    - (instancetype)initWithField:(id)field value:(id)value {
    self = [super init];
    if (!self) {
        return nil;
    }

    self.field = field;
    self.value = value;

    return self;
}
   
   - (NSString *)URLEncodedStringValue {
    if (!self.value || [self.value isEqual:[NSNull null]]) {
        return AFPercentEscapedStringFromString([self.field description]);
    } else {
        return [NSString stringWithFormat:@"%@=%@", AFPercentEscapedStringFromString([self.field description]), AFPercentEscapedStringFromString([self.value description])];
    }
}
```

方法很简单，现在我们也很容易理解这整个转码过程了，我们举个例子梳理下，就是以下这3步：
```
@{ 
     @"name" : @"bang", 
     @"phone": @{@"mobile": @"xx", @"home": @"xx"}, 
     @"families": @[@"father", @"mother"], 
     @"nums": [NSSet setWithObjects:@"1", @"2", nil] 
} 
-> 
@[ 
     field: @"name", value: @"bang", 
     field: @"phone[mobile]", value: @"xx", 
     field: @"phone[home]", value: @"xx", 
     field: @"families[]", value: @"father", 
     field: @"families[]", value: @"mother", 
     field: @"nums", value: @"1", 
     field: @"nums", value: @"2", 
] 
-> 
name=bang&phone[mobile]=xx&phone[home]=xx&families[]=father&families[]=mother&nums=1&num=2
```

至此，我们原来的容器类型的参数，就这样变成字符串类型了。
紧接着这个方法还根据该request中请求类型，来判断参数字符串应该如何设置到request中去。如果是GET、HEAD、DELETE，则把参数quey是拼接到url后面的。而POST、PUT是把query拼接到http body中的:

**

```
if ([self.HTTPMethodsEncodingParametersInURI containsObject:[[request HTTPMethod] uppercaseString]]) {
    if (query && query.length > 0) {
        mutableRequest.URL = [NSURL URLWithString:[[mutableRequest.URL absoluteString] stringByAppendingFormat:mutableRequest.URL.query ? @"&%@" : @"?%@", query]];
    }
} else {
    //post put请求
    
    // #2864: an empty string is a valid x-www-form-urlencoded payload
    if (!query) {
        query = @"";
    }
    if (![mutableRequest valueForHTTPHeaderField:@"Content-Type"]) {
        [mutableRequest setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    }
    //设置请求体
    [mutableRequest setHTTPBody:[query dataUsingEncoding:self.stringEncoding]];
}
```

至此，我们生成了一个request。

###### 我们再回到AFHTTPSessionManager类中来,回到这个方法：

**

```
- (NSURLSessionDataTask *)dataTaskWithHTTPMethod:(NSString *)method
                                       URLString:(NSString *)URLString
                                      parameters:(id)parameters
                                  uploadProgress:(nullable void (^)(NSProgress *uploadProgress)) uploadProgress
                                downloadProgress:(nullable void (^)(NSProgress *downloadProgress)) downloadProgress
                                         success:(void (^)(NSURLSessionDataTask *, id))success
                                         failure:(void (^)(NSURLSessionDataTask *, NSError *))failure
{
    NSError *serializationError = nil;
    //把参数，还有各种东西转化为一个request
    NSMutableURLRequest *request = [self.requestSerializer requestWithMethod:method URLString:[[NSURL URLWithString:URLString relativeToURL:self.baseURL] absoluteString] parameters:parameters error:&serializationError];
    
    if (serializationError) {
        if (failure) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wgnu"
            //如果解析错误，直接返回
            dispatch_async(self.completionQueue ?: dispatch_get_main_queue(), ^{
                failure(nil, serializationError);
            });
#pragma clang diagnostic pop
        }

        return nil;
    }
    
    __block NSURLSessionDataTask *dataTask = nil;
    dataTask = [self dataTaskWithRequest:request
                          uploadProgress:uploadProgress
                        downloadProgress:downloadProgress
                       completionHandler:^(NSURLResponse * __unused response, id responseObject, NSError *error) {
        if (error) {
            if (failure) {
                failure(dataTask, error);
            }
        } else {
            if (success) {
                success(dataTask, responseObject);
            }
        }
    }];
    return dataTask;
}
```

绕了一圈我们又回来了。。

-   我们继续往下看：当解析错误，我们直接调用传进来的fauler的Block失败返回了，这里有一个`self.completionQueue`,这个是我们自定义的，这个是一个GCD的Queue如果设置了那么从这个Queue中回调结果，否则从主队列回调。
-   实际上这个Queue还是挺有用的，之前还用到过。我们公司有自己的一套数据加解密的解析模式，所以我们回调回来的数据并不想是主线程，我们可以设置这个Queue,在分线程进行解析数据，然后自己再调回到主线程去刷新UI。

言归正传，我们接着调用了父类的生成task的方法，并且执行了一个成功和失败的回调，我们接着去父类AFURLSessionManger里看（总算到我们的核心类了..）：

**

```
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                               uploadProgress:(nullable void (^)(NSProgress *uploadProgress)) uploadProgressBlock
                             downloadProgress:(nullable void (^)(NSProgress *downloadProgress)) downloadProgressBlock
                            completionHandler:(nullable void (^)(NSURLResponse *response, id _Nullable responseObject,  NSError * _Nullable error))completionHandler {

    __block NSURLSessionDataTask *dataTask = nil;
    //第一件事，创建NSURLSessionDataTask，里面适配了Ios8以下taskIdentifiers，函数创建task对象。
    //其实现应该是因为iOS 8.0以下版本中会并发地创建多个task对象，而同步有没有做好，导致taskIdentifiers 不唯一…这边做了一个串行处理
    url_session_manager_create_task_safely(^{
        dataTask = [self.session dataTaskWithRequest:request];
    });

    [self addDelegateForDataTask:dataTask uploadProgress:uploadProgressBlock downloadProgress:downloadProgressBlock completionHandler:completionHandler];

    return dataTask;
}
```

-   我们注意到这个方法非常简单，就调用了一个`url_session_manager_create_task_safely()`函数，传了一个Block进去，Block里就是iOS原生生成dataTask的方法。此外，还调用了一个`addDelegateForDataTask`的方法。
-   我们到这先到这个函数里去看看：
```
static void url_session_manager_create_task_safely(dispatch_block_t block) {
    if (NSFoundationVersionNumber < NSFoundationVersionNumber_With_Fixed_5871104061079552_bug) {
        // Fix of bug
        // Open Radar:http://openradar.appspot.com/radar?id=5871104061079552 (status: Fixed in iOS8)
        // Issue about:https://github.com/AFNetworking/AFNetworking/issues/2093
      
      //理解下，第一为什么用sync，因为是想要主线程等在这，等执行完，在返回，因为必须执行完dataTask才有数据，传值才有意义。
      //第二，为什么要用串行队列，因为这块是为了防止ios8以下内部的dataTaskWithRequest是并发创建的，
      //这样会导致taskIdentifiers这个属性值不唯一，因为后续要用taskIdentifiers来作为Key对应delegate。
        dispatch_sync(url_session_manager_creation_queue(), block);
    } else {
        block();
    }
}
static dispatch_queue_t url_session_manager_creation_queue() {
    static dispatch_queue_t af_url_session_manager_creation_queue;
    static dispatch_once_t onceToken;
    //保证了即使是在多线程的环境下，也不会创建其他队列
    dispatch_once(&onceToken, ^{
        af_url_session_manager_creation_queue = dispatch_queue_create("com.alamofire.networking.session.manager.creation", DISPATCH_QUEUE_SERIAL);
    });

    return af_url_session_manager_creation_queue;
}
```
-   方法非常简单，关键是理解这么做的目的：为什么我们不直接去调用  
    `dataTask = [self.session dataTaskWithRequest:request];`  
    非要绕这么一圈，我们点进去bug日志里看看，**原来这是为了适配iOS8的以下，创建session的时候，偶发的情况会出现session的属性taskIdentifier这个值不唯一**，而这个taskIdentifier是我们后面来映射delegate的key,所以它必须是唯一的。
-   **具体原因应该是NSURLSession内部去生成task的时候是用多线程并发去执行的。** 想通了这一点，我们就很好解决了，我们只需要在iOS8以下**同步串行**的去生成task就可以防止这一问题发生（如果还是不理解同步串行的原因，可以看看注释）。
-   题外话：很多同学都会抱怨为什么sync我从来用不到，看，有用到的地方了吧，**很多东西不是没用，而只是你想不到怎么用**。

我们接着看到：

**

```
[self addDelegateForDataTask:dataTask uploadProgress:uploadProgressBlock downloadProgress:downloadProgressBlock completionHandler:completionHandler];
```

调用到：
```
- (void)addDelegateForDataTask:(NSURLSessionDataTask *)dataTask
                uploadProgress:(nullable void (^)(NSProgress *uploadProgress)) uploadProgressBlock
              downloadProgress:(nullable void (^)(NSProgress *downloadProgress)) downloadProgressBlock
             completionHandler:(void (^)(NSURLResponse *response, id responseObject, NSError *error))completionHandler
{
    AFURLSessionManagerTaskDelegate *delegate = [[AFURLSessionManagerTaskDelegate alloc] init];
   
    // AFURLSessionManagerTaskDelegate与AFURLSessionManager建立相互关系
    delegate.manager = self;
    delegate.completionHandler = completionHandler;

    //这个taskDescriptionForSessionTasks用来发送开始和挂起通知的时候会用到,就是用这个值来Post通知，来两者对应
    dataTask.taskDescription = self.taskDescriptionForSessionTasks;
    
    // ***** 将AF delegate对象与 dataTask建立关系
    [self setDelegate:delegate forTask:dataTask];

    // 设置AF delegate的上传进度，下载进度块。
    delegate.uploadProgressBlock = uploadProgressBlock;
    delegate.downloadProgressBlock = downloadProgressBlock;
}
```

-   总结一下:  
    1）这个方法，生成了一个`AFURLSessionManagerTaskDelegate`,这个其实就是AF的自定义代理。我们请求传来的参数，都赋值给这个AF的代理了。  
    2）`delegate.manager = self;`代理把AFURLSessionManager这个类作为属性了,我们可以看到：

**

```
@property (nonatomic, weak) AFURLSessionManager *manager;
```

这个属性是弱引用的，所以不会存在循环引用的问题。  
3）我们调用了`[self setDelegate:delegate forTask:dataTask];`

我们进去看看这个方法做了什么：

**

```
- (void)setDelegate:(AFURLSessionManagerTaskDelegate *)delegate
            forTask:(NSURLSessionTask *)task
{
    //断言，如果没有这个参数，debug下crash在这
    NSParameterAssert(task);
    NSParameterAssert(delegate);

    //加锁保证字典线程安全
    [self.lock lock];
    // 将AF delegate放入以taskIdentifier标记的词典中（同一个NSURLSession中的taskIdentifier是唯一的）
    self.mutableTaskDelegatesKeyedByTaskIdentifier[@(task.taskIdentifier)] = delegate;
   
    // 为AF delegate 设置task 的progress监听
    [delegate setupProgressForTask:task];
    
    //添加task开始和暂停的通知
    [self addNotificationObserverForTask:task];
    [self.lock unlock];
}
```

-   这个方法主要就是把AF代理和task建立映射，存在了一个我们事先声明好的字典里。
-   而要加锁的原因是因为本身我们这个字典属性是mutable的，是线程不安全的。而我们对这些方法的调用，确实是会在复杂的多线程环境中，后面会仔细提到线程问题。
-   还有个`[delegate setupProgressForTask:task];`我们到方法里去看看：

**

```
- (void)setupProgressForTask:(NSURLSessionTask *)task {
    
    __weak __typeof__(task) weakTask = task;

    //拿到上传下载期望的数据大小
    self.uploadProgress.totalUnitCount = task.countOfBytesExpectedToSend;
    self.downloadProgress.totalUnitCount = task.countOfBytesExpectedToReceive;
    
    
    //将上传与下载进度和 任务绑定在一起，直接cancel suspend resume进度条，可以cancel...任务
    [self.uploadProgress setCancellable:YES];
    [self.uploadProgress setCancellationHandler:^{
        __typeof__(weakTask) strongTask = weakTask;
        [strongTask cancel];
    }];
    [self.uploadProgress setPausable:YES];
    [self.uploadProgress setPausingHandler:^{
        __typeof__(weakTask) strongTask = weakTask;
        [strongTask suspend];
    }];
    
    if ([self.uploadProgress respondsToSelector:@selector(setResumingHandler:)]) {
        [self.uploadProgress setResumingHandler:^{
            __typeof__(weakTask) strongTask = weakTask;
            [strongTask resume];
        }];
    }

    [self.downloadProgress setCancellable:YES];
    [self.downloadProgress setCancellationHandler:^{
        __typeof__(weakTask) strongTask = weakTask;
        [strongTask cancel];
    }];
    [self.downloadProgress setPausable:YES];
    [self.downloadProgress setPausingHandler:^{
        __typeof__(weakTask) strongTask = weakTask;
        [strongTask suspend];
    }];

    if ([self.downloadProgress respondsToSelector:@selector(setResumingHandler:)]) {
        [self.downloadProgress setResumingHandler:^{
            __typeof__(weakTask) strongTask = weakTask;
            [strongTask resume];
        }];
    }

    //观察task的这些属性
    [task addObserver:self
           forKeyPath:NSStringFromSelector(@selector(countOfBytesReceived))
              options:NSKeyValueObservingOptionNew
              context:NULL];
    [task addObserver:self
           forKeyPath:NSStringFromSelector(@selector(countOfBytesExpectedToReceive))
              options:NSKeyValueObservingOptionNew
              context:NULL];

    [task addObserver:self
           forKeyPath:NSStringFromSelector(@selector(countOfBytesSent))
              options:NSKeyValueObservingOptionNew
              context:NULL];
    [task addObserver:self
           forKeyPath:NSStringFromSelector(@selector(countOfBytesExpectedToSend))
              options:NSKeyValueObservingOptionNew
              context:NULL];

    //观察progress这两个属性
    [self.downloadProgress addObserver:self
                            forKeyPath:NSStringFromSelector(@selector(fractionCompleted))
                               options:NSKeyValueObservingOptionNew
                               context:NULL];
    [self.uploadProgress addObserver:self
                          forKeyPath:NSStringFromSelector(@selector(fractionCompleted))
                             options:NSKeyValueObservingOptionNew
                             context:NULL];
}
```

-   这个方法也非常简单，主要做了以下几件事：  
    1）设置  `downloadProgress`与`uploadProgress`的一些属性，并且把两者和task的任务状态绑定在了一起。注意这两者都是NSProgress的实例对象，（这里可能又一群小伙伴楞在这了，这是个什么...）简单来说，这就是iOS7引进的一个用来管理进度的类，可以开始，暂停，取消，完整的对应了task的各种状态，当progress进行各种操作的时候，task也会引发对应操作。  
    2）给task和progress的各个属及添加KVO监听，至于监听了干什么用，我们接着往下看：

**

```
 - (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSString *,id> *)change context:(void *)context {
    
    //是task
    if ([object isKindOfClass:[NSURLSessionTask class]] || [object isKindOfClass:[NSURLSessionDownloadTask class]]) {
        //给进度条赋新值
        if ([keyPath isEqualToString:NSStringFromSelector(@selector(countOfBytesReceived))]) {
            self.downloadProgress.completedUnitCount = [change[NSKeyValueChangeNewKey] longLongValue];
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(countOfBytesExpectedToReceive))]) {
            self.downloadProgress.totalUnitCount = [change[NSKeyValueChangeNewKey] longLongValue];
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(countOfBytesSent))]) {
            self.uploadProgress.completedUnitCount = [change[NSKeyValueChangeNewKey] longLongValue];
        } else if ([keyPath isEqualToString:NSStringFromSelector(@selector(countOfBytesExpectedToSend))]) {
            self.uploadProgress.totalUnitCount = [change[NSKeyValueChangeNewKey] longLongValue];
        }
    }
    //上面的赋新值会触发这两个，调用block回调，用户拿到进度
    else if ([object isEqual:self.downloadProgress]) {
        if (self.downloadProgressBlock) {
            self.downloadProgressBlock(object);
        }
    }
    else if ([object isEqual:self.uploadProgress]) {
        if (self.uploadProgressBlock) {
            self.uploadProgressBlock(object);
        }
    }
}
```

-   方法非常简单直观，主要就是如果task触发KVO,则给progress进度赋值，应为赋值了，所以会触发progress的KVO，也会调用到这里，然后去执行我们传进来的`downloadProgressBlock`和`uploadProgressBlock`。主要的作用就是为了让进度实时的传递。
-   主要是观摩一下大神的写代码的结构，这个解耦的编程思想，不愧是大神...
-   还有一点需要注意：我们之前的setProgress和这个KVO监听，都是在我们AF自定义的delegate内的，是**有一个task就会有一个delegate的。所以说我们是每个task都会去监听这些属性，分别在各自的AF代理内。** 看到这，可能有些小伙伴会有点乱，没关系。等整个讲完之后我们还会详细的去讲捋一捋manager、task、还有AF自定义代理三者之前的对应关系。

到这里我们整个对task的处理就完成了。


接着task就开始请求网络了，还记得我们初始化方法中：

```
self.session = [NSURLSession sessionWithConfiguration:self.sessionConfiguration delegate:self delegateQueue:self.operationQueue];
```

我们把AFUrlSessionManager作为了所有的task的delegate。当我们请求网络的时候，这些代理开始调用了：

![image.jpeg](https://p1-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/5c5bab6379834b23b9e9eaf9281cb0e7~tplv-k3u1fbpfcp-watermark.image?)
  -   AFUrlSessionManager一共实现了如上图所示这么一大堆NSUrlSession相关的代理。（小伙伴们的顺序可能不一样，楼主根据代理隶属重新排序了一下）

-   而只转发了其中3条到AF自定义的delegate中：
![image.jpeg](https://p9-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/407762f83cba4c2496819cbbd4ebe7a9~tplv-k3u1fbpfcp-watermark.image?)
  这就是我们一开始说的，AFUrlSessionManager对这一大堆代理做了一些公共的处理，而转发到AF自定义代理的3条，则负责把每个task对应的数据回调出去。

又有小伙伴问了，我们设置的这个代理不是`NSURLSessionDelegate`吗？怎么能响应NSUrlSession这么多代理呢？我们点到类的声明文件中去看看：

**

```
@protocol NSURLSessionDelegate <NSObject>
@protocol NSURLSessionTaskDelegate <NSURLSessionDelegate>
@protocol NSURLSessionDataDelegate <NSURLSessionTaskDelegate>
@protocol NSURLSessionDownloadDelegate <NSURLSessionTaskDelegate>
@protocol NSURLSessionStreamDelegate <NSURLSessionTaskDelegate>
```

-   我们可以看到这些代理都是继承关系，而在`NSURLSession`实现中，只要设置了这个代理，它会去判断这些所有的代理，是否`respondsToSelector`这些代理中的方法，如果响应了就会去调用。
-   而AF还重写了`respondsToSelector`方法:


```
 - (BOOL)respondsToSelector:(SEL)selector {
    
    //复写了selector的方法，这几个方法是在本类有实现的，但是如果外面的Block没赋值的话，则返回NO，相当于没有实现！
    if (selector == @selector(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:)) {
        return self.taskWillPerformHTTPRedirection != nil;
    } else if (selector == @selector(URLSession:dataTask:didReceiveResponse:completionHandler:)) {
        return self.dataTaskDidReceiveResponse != nil;
    } else if (selector == @selector(URLSession:dataTask:willCacheResponse:completionHandler:)) {
        return self.dataTaskWillCacheResponse != nil;
    } else if (selector == @selector(URLSessionDidFinishEventsForBackgroundURLSession:)) {
        return self.didFinishEventsForBackgroundURLSession != nil;
    }
    return [[self class] instancesRespondToSelector:selector];
}
```

这样如果没实现这些我们自定义的Block也不会去回调这些代理。因为本身某些代理，只执行了这些自定义的Block，如果Block都没有赋值，那我们调用代理也没有任何意义。  
讲到这，我们顺便看看AFUrlSessionManager的一些自定义Block：

```
@property (readwrite, nonatomic, copy) AFURLSessionDidBecomeInvalidBlock sessionDidBecomeInvalid;
@property (readwrite, nonatomic, copy) AFURLSessionDidReceiveAuthenticationChallengeBlock sessionDidReceiveAuthenticationChallenge;
@property (readwrite, nonatomic, copy) AFURLSessionDidFinishEventsForBackgroundURLSessionBlock didFinishEventsForBackgroundURLSession;
@property (readwrite, nonatomic, copy) AFURLSessionTaskWillPerformHTTPRedirectionBlock taskWillPerformHTTPRedirection;
@property (readwrite, nonatomic, copy) AFURLSessionTaskDidReceiveAuthenticationChallengeBlock taskDidReceiveAuthenticationChallenge;
@property (readwrite, nonatomic, copy) AFURLSessionTaskNeedNewBodyStreamBlock taskNeedNewBodyStream;
@property (readwrite, nonatomic, copy) AFURLSessionTaskDidSendBodyDataBlock taskDidSendBodyData;
@property (readwrite, nonatomic, copy) AFURLSessionTaskDidCompleteBlock taskDidComplete;
@property (readwrite, nonatomic, copy) AFURLSessionDataTaskDidReceiveResponseBlock dataTaskDidReceiveResponse;
@property (readwrite, nonatomic, copy) AFURLSessionDataTaskDidBecomeDownloadTaskBlock dataTaskDidBecomeDownloadTask;
@property (readwrite, nonatomic, copy) AFURLSessionDataTaskDidReceiveDataBlock dataTaskDidReceiveData;
@property (readwrite, nonatomic, copy) AFURLSessionDataTaskWillCacheResponseBlock dataTaskWillCacheResponse;
@property (readwrite, nonatomic, copy) AFURLSessionDownloadTaskDidFinishDownloadingBlock downloadTaskDidFinishDownloading;
@property (readwrite, nonatomic, copy) AFURLSessionDownloadTaskDidWriteDataBlock downloadTaskDidWriteData;
@property (readwrite, nonatomic, copy) AFURLSessionDownloadTaskDidResumeBlock downloadTaskDidResume;
```

各自对应的还有一堆这样的set方法：

**

```
 - (void)setSessionDidBecomeInvalidBlock:(void (^)(NSURLSession *session, NSError *error))block {
    self.sessionDidBecomeInvalid = block;
}
```

方法都是一样的，就不重复粘贴占篇幅了。  
主要谈谈这个设计思路

-   作者用@property把这个些Block属性在.m文件中声明,然后复写了set方法。
-   然后在.h中去声明这些set方法：

```
   - (void)setSessionDidBecomeInvalidBlock:(nullable void (^)(NSURLSession *session, NSError *error))block;
```

为什么要绕这么一大圈呢？**原来这是为了我们这些用户使用起来方便，调用set方法去设置这些Block，能很清晰的看到Block的各个参数与返回值。** 大神的精髓的编程思想无处不体现...
接下来我们就讲讲这些代理方法做了什么（按照顺序来）：

###### NSURLSessionDelegate

###### 代理1：

```
//当前这个session已经失效时，该代理方法被调用。
/*
 如果你使用finishTasksAndInvalidate函数使该session失效，
 那么session首先会先完成最后一个task，然后再调用URLSession:didBecomeInvalidWithError:代理方法，
 如果你调用invalidateAndCancel方法来使session失效，那么该session会立即调用上面的代理方法。
 */
- (void)URLSession:(NSURLSession *)session
didBecomeInvalidWithError:(NSError *)error
{
    if (self.sessionDidBecomeInvalid) {
        self.sessionDidBecomeInvalid(session, error);
    }

    [[NSNotificationCenter defaultCenter] postNotificationName:AFURLSessionDidInvalidateNotification object:session];
}
```

-   方法调用时机注释写的很清楚，就调用了一下我们自定义的Block,还发了一个失效的通知，至于这个通知有什么用。很抱歉，AF没用它做任何事，只是发了...目的是用户自己可以利用这个通知做什么事吧。
-   其实AF大部分通知都是如此。当然，还有一部分通知AF还是有自己用到的，包括配合对UIKit的一些扩展来使用，后面我们会有单独篇幅展开讲讲这些UIKit的扩展类的实现。

  ###### 代理2：

**

```
//2、https认证
- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler
{
    //挑战处理类型为 默认
    /*
     NSURLSessionAuthChallengePerformDefaultHandling：默认方式处理
     NSURLSessionAuthChallengeUseCredential：使用指定的证书
     NSURLSessionAuthChallengeCancelAuthenticationChallenge：取消挑战
     */
    NSURLSessionAuthChallengeDisposition disposition = NSURLSessionAuthChallengePerformDefaultHandling;
    __block NSURLCredential *credential = nil;

    // sessionDidReceiveAuthenticationChallenge是自定义方法，用来如何应对服务器端的认证挑战

    if (self.sessionDidReceiveAuthenticationChallenge) {
        disposition = self.sessionDidReceiveAuthenticationChallenge(session, challenge, &credential);
    } else {
        // 此处服务器要求客户端的接收认证挑战方法是NSURLAuthenticationMethodServerTrust
        // 也就是说服务器端需要客户端返回一个根据认证挑战的保护空间提供的信任（即challenge.protectionSpace.serverTrust）产生的挑战证书。
       
        // 而这个证书就需要使用credentialForTrust:来创建一个NSURLCredential对象
        if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
            
            // 基于客户端的安全策略来决定是否信任该服务器，不信任的话，也就没必要响应挑战
            if ([self.securityPolicy evaluateServerTrust:challenge.protectionSpace.serverTrust forDomain:challenge.protectionSpace.host]) {
               
                // 创建挑战证书（注：挑战方式为UseCredential和PerformDefaultHandling都需要新建挑战证书）
                credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
                // 确定挑战的方式
                if (credential) {
                    //证书挑战
                    disposition = NSURLSessionAuthChallengeUseCredential;
                } else {
                    //默认挑战  唯一区别，下面少了这一步！
                    disposition = NSURLSessionAuthChallengePerformDefaultHandling;
                }
            } else {
                //取消挑战
                disposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;
            }
        } else {
            //默认挑战方式
            disposition = NSURLSessionAuthChallengePerformDefaultHandling;
        }
    }
    //完成挑战
    if (completionHandler) {
        completionHandler(disposition, credential);
    }
}
```

> -   函数作用：  
>     web服务器接收到客户端请求时，有时候需要先验证客户端是否为正常用户，再决定是够返回真实数据。这种情况称之为服务端要求客户端接收挑战（NSURLAuthenticationChallenge *challenge）。接收到挑战后，客户端要根据服务端传来的challenge来生成completionHandler所需的NSURLSessionAuthChallengeDisposition disposition和NSURLCredential *credential（disposition指定应对这个挑战的方法，而credential是客户端生成的挑战证书，注意只有challenge中认证方法为NSURLAuthenticationMethodServerTrust的时候，才需要生成挑战证书）。最后调用completionHandler回应服务器端的挑战。

-   函数讨论：  
    该代理方法会在下面两种情况调用：

1.  当服务器端要求客户端提供证书时或者进行NTLM认证（Windows NT LAN Manager，微软提出的WindowsNT挑战/响应验证机制）时，此方法允许你的app提供正确的挑战证书。
1.  当某个session使用SSL/TLS协议，第一次和服务器端建立连接的时候，服务器会发送给iOS客户端一个证书，此方法允许你的app验证服务期端的证书链（certificate keychain）  
    注：如果你没有实现该方法，该session会调用其NSURLSessionTaskDelegate的代理方法URLSession:task:didReceiveChallenge:completionHandler: 。

这里，我把官方文档对这个方法的描述翻译了一下。  
总结一下，这个方法其实就是做https认证的。看看上面的注释，大概能看明白这个方法做认证的步骤，我们还是如果有自定义的做认证的Block，则调用我们自定义的，否则去执行默认的认证步骤，最后调用完成认证：

```
//完成挑战 
if (completionHandler) { 
      completionHandler(disposition, credential); 
}
```

###### 代理3：

```
//3、 当session中所有已经入队的消息被发送出去后，会调用该代理方法。
- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    if (self.didFinishEventsForBackgroundURLSession) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.didFinishEventsForBackgroundURLSession(session);
        });
    }
}
```

官方文档翻译：

> 函数讨论：

-   在iOS中，当一个后台传输任务完成或者后台传输时需要证书，而此时你的app正在后台挂起，那么你的app在后台会自动重新启动运行，并且这个app的UIApplicationDelegate会发送一个application:handleEventsForBackgroundURLSession:completionHandler:消息。该消息包含了对应后台的session的identifier，而且这个消息会导致你的app启动。你的app随后应该先存储completion handler，然后再使用相同的identifier创建一个background configuration，并根据这个background configuration创建一个新的session。这个新创建的session会自动与后台任务重新关联在一起。
-   当你的app获取了一个URLSessionDidFinishEventsForBackgroundURLSession:消息，这就意味着之前这个session中已经入队的所有消息都转发出去了，这时候再调用先前存取的completion handler是安全的，或者因为内部更新而导致调用completion handler也是安全的。

###### NSURLSessionTaskDelegate

###### 代理4：

```
//被服务器重定向的时候调用
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler
{
    NSURLRequest *redirectRequest = request;

    // step1. 看是否有对应的user block 有的话转发出去，通过这4个参数，返回一个NSURLRequest类型参数，request转发、网络重定向.
    if (self.taskWillPerformHTTPRedirection) {
        //用自己自定义的一个重定向的block实现，返回一个新的request。
        redirectRequest = self.taskWillPerformHTTPRedirection(session, task, response, request);
    }

    if (completionHandler) {
        // step2. 用request重新请求
        completionHandler(redirectRequest);
    }
}
```

-   一开始我以为这个方法是类似`NSURLProtocol`，可以在请求时自己主动的去重定向request，后来发现不是，这个方法是在服务器去重定向的时候，才会被调用。为此我写了段简单的PHP测了测：

**

```
<?php
defined('BASEPATH') OR exit('No direct script access allowed');

class Welcome extends CI_Controller {
    public function index()
    {
        header("location: http://www.huixionghome.cn/");
    }
}
```

证实确实如此，当我们服务器重定向的时候，代理就被调用了，我们可以去重新定义这个重定向的request。

-   关于这个代理还有一些需要注意的地方：

> 此方法只会在default session或者ephemeral session中调用，而在background session中，session task会自动重定向。

这里指的模式是我们一开始Init的模式：

**

```
if (!configuration) {
    configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
}
self.sessionConfiguration = configuration;
```

这个模式总共分为3种：

> 对于NSURLSession对象的初始化需要使用NSURLSessionConfiguration，而NSURLSessionConfiguration有三个类工厂方法：  
> +defaultSessionConfiguration 返回一个标准的 configuration，这个配置实际上与 NSURLConnection 的网络堆栈（networking stack）是一样的，具有相同的共享 NSHTTPCookieStorage，共享 NSURLCache 和共享NSURLCredentialStorage。  
> +ephemeralSessionConfiguration 返回一个预设配置，这个配置中不会对缓存，Cookie 和证书进行持久性的存储。这对于实现像秘密浏览这种功能来说是很理想的。  
> +backgroundSessionConfiguration:(NSString *)identifier 的独特之处在于，它会创建一个后台 session。后台 session 不同于常规的，普通的 session，它甚至可以在应用程序挂起，退出或者崩溃的情况下运行上传和下载任务。初始化时指定的标识符，被用于向任何可能在进程外恢复后台传输的守护进程（daemon）提供上下文。

###### 代理5：

```
//https认证
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler
{
    NSURLSessionAuthChallengeDisposition disposition = NSURLSessionAuthChallengePerformDefaultHandling;
    __block NSURLCredential *credential = nil;

    if (self.taskDidReceiveAuthenticationChallenge) {
        disposition = self.taskDidReceiveAuthenticationChallenge(session, task, challenge, &credential);
    } else {
        if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
            if ([self.securityPolicy evaluateServerTrust:challenge.protectionSpace.serverTrust forDomain:challenge.protectionSpace.host]) {
                disposition = NSURLSessionAuthChallengeUseCredential;
                credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
            } else {
                disposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;
            }
        } else {
            disposition = NSURLSessionAuthChallengePerformDefaultHandling;
        }
    }

    if (completionHandler) {
        completionHandler(disposition, credential);
    }
}
```

-   鉴于篇幅，就不去贴官方文档的翻译了，大概总结一下：  
    之前我们也有一个https认证，功能一样，执行的内容也完全一样。
-   区别在于这个是non-session-level级别的认证，而之前的是session-level级别的。
-   相对于它，多了一个参数task,然后调用我们自定义的Block会多回传这个task作为参数，这样我们就可以根据每个task去自定义我们需要的https认证方式。

###### 代理6：

```
//当一个session task需要发送一个新的request body stream到服务器端的时候，调用该代理方法。

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
 needNewBodyStream:(void (^)(NSInputStream *bodyStream))completionHandler
{
    
    NSInputStream *inputStream = nil;

    //有自定义的taskNeedNewBodyStream,用自定义的，不然用task里原始的stream
    if (self.taskNeedNewBodyStream) {
        inputStream = self.taskNeedNewBodyStream(session, task);
    } else if (task.originalRequest.HTTPBodyStream && [task.originalRequest.HTTPBodyStream conformsToProtocol:@protocol(NSCopying)]) {
        inputStream = [task.originalRequest.HTTPBodyStream copy];
    }

    if (completionHandler) {
        completionHandler(inputStream);
    }
}
```

-   该代理方法会在下面两种情况被调用：

    1.  如果task是由uploadTaskWithStreamedRequest:创建的，那么提供初始的request body stream时候会调用该代理方法。
    1.  因为认证挑战或者其他可恢复的服务器错误，而导致需要客户端重新发送一个含有body stream的request，这时候会调用该代理。

###### 代理7：

```
/*
 //周期性地通知代理发送到服务器端数据的进度。
 */

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
   didSendBodyData:(int64_t)bytesSent
    totalBytesSent:(int64_t)totalBytesSent
totalBytesExpectedToSend:(int64_t)totalBytesExpectedToSend
{
     // 如果totalUnitCount获取失败，就使用HTTP header中的Content-Length作为totalUnitCount

    int64_t totalUnitCount = totalBytesExpectedToSend;
    if(totalUnitCount == NSURLSessionTransferSizeUnknown) {
        NSString *contentLength = [task.originalRequest valueForHTTPHeaderField:@"Content-Length"];
        if(contentLength) {
            totalUnitCount = (int64_t) [contentLength longLongValue];
        }
    }

    if (self.taskDidSendBodyData) {
        self.taskDidSendBodyData(session, task, bytesSent, totalBytesSent, totalUnitCount);
    }
}
```

-   就是每次发送数据给服务器，会回调这个方法，通知已经发送了多少，总共要发送多少。
-   代理方法里也就是仅仅调用了我们自定义的Block而已。

######

###### 代理8：

**

```
/*
 task完成之后的回调，成功和失败都会回调这里
 函数讨论：
 注意这里的error不会报告服务期端的error，他表示的是客户端这边的eroor，比如无法解析hostname或者连不上host主机。
 */
- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error
{   
    //根据task去取我们一开始创建绑定的delegate
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:task];

    // delegate may be nil when completing a task in the background
    if (delegate) {
        //把代理转发给我们绑定的delegate
        [delegate URLSession:session task:task didCompleteWithError:error];
        //转发完移除delegate
        [self removeDelegateForTask:task];
    }
   
    //自定义Block回调
    if (self.taskDidComplete) {
        self.taskDidComplete(session, task, error);
    }  
}
```

这个代理就是task完成了的回调，方法内做了下面这几件事：

-   在这里我们拿到了之前和这个task对应绑定的AF的delegate:

**

```
 - (AFURLSessionManagerTaskDelegate *)delegateForTask:(NSURLSessionTask *)task {
    NSParameterAssert(task);

    AFURLSessionManagerTaskDelegate *delegate = nil;
    [self.lock lock];
    delegate = self.mutableTaskDelegatesKeyedByTaskIdentifier[@(task.taskIdentifier)];
    [self.lock unlock];

    return delegate;
}
```

-   去转发了调用了AF代理的方法。这个等我们下面讲完NSUrlSession的代理之后会详细说。
-   然后把这个AF的代理和task的绑定解除了，并且移除了相关的progress和通知：

**

```
 - (void)removeDelegateForTask:(NSURLSessionTask *)task {
    NSParameterAssert(task);
    //移除跟AF代理相关的东西
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:task];
    [self.lock lock];
    [delegate cleanUpProgressForTask:task];
    [self removeNotificationObserverForTask:task];
    [self.mutableTaskDelegatesKeyedByTaskIdentifier removeObjectForKey:@(task.taskIdentifier)];
    [self.lock unlock];
}
```

-   调用了自定义的Blcok:`self.taskDidComplete(session, task, error);`  
    代码还是很简单的，至于这个通知，我们等会再来补充吧。

###### NSURLSessionDataDelegate:

###### 代理9：

```
//收到服务器响应后调用
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler
{
    //设置默认为继续进行
    NSURLSessionResponseDisposition disposition = NSURLSessionResponseAllow;

    //自定义去设置
    if (self.dataTaskDidReceiveResponse) {
        disposition = self.dataTaskDidReceiveResponse(session, dataTask, response);
    }

    if (completionHandler) {
        completionHandler(disposition);
    }
}
```

官方文档翻译如下：

> 函数作用：  
> 告诉代理，该data task获取到了服务器端传回的最初始回复（response）。注意其中的completionHandler这个block，通过传入一个类型为NSURLSessionResponseDisposition的变量来决定该传输任务接下来该做什么：  
> NSURLSessionResponseAllow 该task正常进行  
> NSURLSessionResponseCancel 该task会被取消  
> NSURLSessionResponseBecomeDownload 会调用URLSession:dataTask:didBecomeDownloadTask:方法来新建一个download task以代替当前的data task  
> NSURLSessionResponseBecomeStream 转成一个StreamTask

> 函数讨论：  
> 该方法是可选的，除非你必须支持“multipart/x-mixed-replace”类型的content-type。因为如果你的request中包含了这种类型的content-type，服务器会将数据分片传回来，而且每次传回来的数据会覆盖之前的数据。每次返回新的数据时，session都会调用该函数，你应该在这个函数中合理地处理先前的数据，否则会被新数据覆盖。如果你没有提供该方法的实现，那么session将会继续任务，也就是说会覆盖之前的数据。

总结一下：

-   当你把添加`content-type`的类型为`multipart/x-mixed-replace`那么服务器的数据会分片的传回来。然后这个方法是每次接受到对应片响应的时候会调被调用。你可以去设置上述4种对这个task的处理。
-   如果我们实现了自定义Block，则调用一下，不然就用默认的`NSURLSessionResponseAllow`方式。

###### 代理10：

```
//上面的代理如果设置为NSURLSessionResponseBecomeDownload，则会调用这个方法
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didBecomeDownloadTask:(NSURLSessionDownloadTask *)downloadTask
{
    //因为转变了task，所以要对task做一个重新绑定
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:dataTask];
    if (delegate) {
        [self removeDelegateForTask:dataTask];
        [self setDelegate:delegate forTask:downloadTask];
    }
    //执行自定义Block
    if (self.dataTaskDidBecomeDownloadTask) {
        self.dataTaskDidBecomeDownloadTask(session, dataTask, downloadTask);
    }
}
```

-   这个代理方法是被上面的代理方法触发的，作用就是新建一个downloadTask，替换掉当前的dataTask。所以我们在这里做了AF自定义代理的重新绑定操作。
-   调用自定义Block。

按照顺序来，其实还有个AF没有去实现的代理：

**

```
//AF没实现的代理
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
didBecomeStreamTask:(NSURLSessionStreamTask *)streamTask;
```

这个也是之前的那个代理，设置为`NSURLSessionResponseBecomeStream`则会调用到这个代理里来。会新生成一个`NSURLSessionStreamTask`来替换掉之前的dataTask。

###### 代理11：

```
//当我们获取到数据就会调用，会被反复调用，请求到的数据就在这被拼装完整
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data
{
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:dataTask];
    [delegate URLSession:session dataTask:dataTask didReceiveData:data];
    if (self.dataTaskDidReceiveData) {
        self.dataTaskDidReceiveData(session, dataTask, data);
    }
}
```

-   这个方法和上面`didCompleteWithError`算是NSUrlSession的代理中最重要的两个方法了。
-   我们转发了这个方法到AF的代理中去，所以数据的拼接都是在AF的代理中进行的。这也是情理中的，毕竟每个响应数据都是对应各个task，各个AF代理的。在AFURLSessionManager都只是做一些公共的处理。

###### 代理12：

```
/*当task接收到所有期望的数据后，session会调用此代理方法。
*/
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
 willCacheResponse:(NSCachedURLResponse *)proposedResponse
 completionHandler:(void (^)(NSCachedURLResponse *cachedResponse))completionHandler
{
    NSCachedURLResponse *cachedResponse = proposedResponse;

    if (self.dataTaskWillCacheResponse) {
        cachedResponse = self.dataTaskWillCacheResponse(session, dataTask, proposedResponse);
    }
    if (completionHandler) {
        completionHandler(cachedResponse);
    }
}
```

官方文档翻译如下：

> 函数作用：  
> 询问data task或上传任务（upload task）是否缓存response。

> 函数讨论：  
> 当task接收到所有期望的数据后，session会调用此代理方法。如果你没有实现该方法，那么就会使用创建session时使用的configuration对象决定缓存策略。这个代理方法最初的目的是为了阻止缓存特定的URLs或者修改NSCacheURLResponse对象相关的userInfo字典。  
> 该方法只会当request决定缓存response时候调用。作为准则，responses只会当以下条件都成立的时候返回缓存：  
> 该request是HTTP或HTTPS URL的请求（或者你自定义的网络协议，并且确保该协议支持缓存）  
> 确保request请求是成功的（返回的status code为200-299）  
> 返回的response是来自服务器端的，而非缓存中本身就有的  
> 提供的NSURLRequest对象的缓存策略要允许进行缓存  
> 服务器返回的response中与缓存相关的header要允许缓存  
> 该response的大小不能比提供的缓存空间大太多（比如你提供了一个磁盘缓存，那么response大小一定不能比磁盘缓存空间还要大5%）

-   总结一下就是一个用来缓存response的方法，方法中调用了我们自定义的Block，自定义一个response用来缓存。

###### NSURLSessionDownloadDelegate

###### 代理13：
```
//下载完成的时候调用

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location
{
    AFURLSessionManagerTaskDelegate *delegate = [self delegateForTask:downloadTask];
    //这个是session的，也就是全局的，后面的个人代理也会做同样的这件事
    if (self.downloadTaskDidFinishDownloading) {
        
        //调用自定义的block拿到文件存储的地址
        NSURL *fileURL = self.downloadTaskDidFinishDownloading(session, downloadTask, location);
        if (fileURL) {
            delegate.downloadFileURL = fileURL;
            NSError *error = nil;
            //从临时的下载路径移动至我们需要的路径
            [[NSFileManager defaultManager] moveItemAtURL:location toURL:fileURL error:&error];
            //如果移动出错
            if (error) {
                [[NSNotificationCenter defaultCenter] postNotificationName:AFURLSessionDownloadTaskDidFailToMoveFileNotification object:downloadTask userInfo:error.userInfo];
            }
            return;
        }
    }
    //转发代理
    if (delegate) {
        [delegate URLSession:session downloadTask:downloadTask didFinishDownloadingToURL:location];
    }
}
```

-   这个方法和之前的两个方法：

**

```
 - (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)taskdidCompleteWithError:(NSError *)error;
 - (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data;
```

总共就这3个方法，被转调到AF自定义delegate中。

-   方法做了什么看注释应该很简单，就不赘述了。

###### 代理14：

```
//周期性地通知下载进度调用
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite
{
    if (self.downloadTaskDidWriteData) {
        self.downloadTaskDidWriteData(session, downloadTask, bytesWritten, totalBytesWritten, totalBytesExpectedToWrite);
    }
}
```

简单说一下这几个参数:  
`bytesWritten` 表示自上次调用该方法后，接收到的数据字节数  
`totalBytesWritten`表示目前已经接收到的数据字节数  
`totalBytesExpectedToWrite` 表示期望收到的文件总字节数，是由Content-Length header提供。如果没有提供，默认是NSURLSessionTransferSizeUnknown。

###### 代理15：
```
//当下载被取消或者失败后重新恢复下载时调用
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
 didResumeAtOffset:(int64_t)fileOffset
expectedTotalBytes:(int64_t)expectedTotalBytes
{
    //交给自定义的Block去调用
    if (self.downloadTaskDidResume) {
        self.downloadTaskDidResume(session, downloadTask, fileOffset, expectedTotalBytes);
    }
}
```

官方文档翻译：

> 函数作用：  
> 告诉代理，下载任务重新开始下载了。

> 函数讨论：  
> 如果一个正在下载任务被取消或者失败了，你可以请求一个resumeData对象（比如在userInfo字典中通过NSURLSessionDownloadTaskResumeData这个键来获取到resumeData）并使用它来提供足够的信息以重新开始下载任务。  
> 随后，你可以使用resumeData作为downloadTaskWithResumeData:或downloadTaskWithResumeData:completionHandler:的参数。当你调用这些方法时，你将开始一个新的下载任务。一旦你继续下载任务，session会调用它的代理方法URLSession:downloadTask:didResumeAtOffset:expectedTotalBytes:其中的downloadTask参数表示的就是新的下载任务，这也意味着下载重新开始了。

总结一下：

-   **其实这个就是用来做断点续传的代理方法。** 可以在下载失败的时候，拿到我们失败的拼接的部分`resumeData`，然后用去调用`downloadTaskWithResumeData：`就会调用到这个代理方法来了。
-   其中注意：`fileOffset`这个参数，如果文件缓存策略或者最后文件更新日期阻止重用已经存在的文件内容，那么该值为0。否则，该值表示当前已经下载data的偏移量。
-   方法中仅仅调用了`downloadTaskDidResume`自定义Block。

至此NSUrlSesssion的delegate讲完了。大概总结下：

-   每个代理方法对应一个我们自定义的Block,如果Block被赋值了，那么就调用它。
-   在这些代理方法里，我们做的处理都是相对于这个sessionManager所有的request的。**是公用的处理。**
-   转发了3个代理方法到AF的deleagate中去了，AF中的deleagate是需要对应每个task去**私有化处理的**。

  
  
 ### 接下来我们来看转发到AF的deleagate，一共3个方法：

###### AF代理1：

```
//AF实现的代理！被从urlsession那转发到这

- (void)URLSession:(__unused NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error
{
 
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wgnu"
    
    //1）强引用self.manager，防止被提前释放；因为self.manager声明为weak,类似Block

    __strong AFURLSessionManager *manager = self.manager;

    __block id responseObject = nil;

    //用来存储一些相关信息，来发送通知用的
    __block NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    //存储responseSerializer响应解析对象
    userInfo[AFNetworkingTaskDidCompleteResponseSerializerKey] = manager.responseSerializer;

    //Performance Improvement from #2672
    
    //注意这行代码的用法，感觉写的很Nice...把请求到的数据data传出去，然后就不要这个值了释放内存
    NSData *data = nil;
    if (self.mutableData) {
        data = [self.mutableData copy];
        //We no longer need the reference, so nil it out to gain back some memory.
        self.mutableData = nil;
    }

    //继续给userinfo填数据
    if (self.downloadFileURL) {
        userInfo[AFNetworkingTaskDidCompleteAssetPathKey] = self.downloadFileURL;
    } else if (data) {
        userInfo[AFNetworkingTaskDidCompleteResponseDataKey] = data;
    }
    //错误处理
    if (error) {
        
        userInfo[AFNetworkingTaskDidCompleteErrorKey] = error;
        
        //可以自己自定义完成组 和自定义完成queue,完成回调
        dispatch_group_async(manager.completionGroup ?: url_session_manager_completion_group(), manager.completionQueue ?: dispatch_get_main_queue(), ^{
            if (self.completionHandler) {
                self.completionHandler(task.response, responseObject, error);
            }
            //主线程中发送完成通知
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingTaskDidCompleteNotification object:task userInfo:userInfo];
            });
        });
    } else {
        //url_session_manager_processing_queue AF的并行队列
        dispatch_async(url_session_manager_processing_queue(), ^{
            NSError *serializationError = nil;
            
            //解析数据
            responseObject = [manager.responseSerializer responseObjectForResponse:task.response data:data error:&serializationError];
            
            //如果是下载文件，那么responseObject为下载的路径
            if (self.downloadFileURL) {
                responseObject = self.downloadFileURL;
            }

            //写入userInfo
            if (responseObject) {
                userInfo[AFNetworkingTaskDidCompleteSerializedResponseKey] = responseObject;
            }
            
            //如果解析错误
            if (serializationError) {
                userInfo[AFNetworkingTaskDidCompleteErrorKey] = serializationError;
            }
            //回调结果
            dispatch_group_async(manager.completionGroup ?: url_session_manager_completion_group(), manager.completionQueue ?: dispatch_get_main_queue(), ^{
                if (self.completionHandler) {
                    self.completionHandler(task.response, responseObject, serializationError);
                }

                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingTaskDidCompleteNotification object:task userInfo:userInfo];
                });
            });
        });
    }
#pragma clang diagnostic pop
}
```

这个方法是NSUrlSession任务完成的代理方法中，主动调用过来的。配合注释，应该代码很容易读，这个方法大概做了以下几件事：

1.  生成了一个存储这个task相关信息的字典：`userInfo`，这个字典是用来作为发送任务完成的通知的参数。

-   判断了参数`error`的值，来区分请求成功还是失败。
-   如果成功则在一个AF的并行queue中，去做数据解析等后续操作：

**

```
static dispatch_queue_t url_session_manager_processing_queue() {
    static dispatch_queue_t af_url_session_manager_processing_queue;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        af_url_session_manager_processing_queue = dispatch_queue_create("com.alamofire.networking.session.manager.processing", DISPATCH_QUEUE_CONCURRENT);
    });

    return af_url_session_manager_processing_queue;
}
```

注意AF的优化的点，虽然代理回调是串行的(不明白可以见本文最后)。但是数据解析这种费时操作，确是用并行线程来做的。

-   然后根据我们一开始设置的`responseSerializer`来解析data。如果解析成功，调用成功的回调，否则调用失败的回调。  
    我们重点来看看返回数据解析这行：


```
responseObject = [manager.responseSerializer responseObjectForResponse:task.response data:data error:&serializationError];
```

我们点进去看看：

```
  @protocol AFURLResponseSerialization <NSObject, NSSecureCoding, NSCopying>

  - (nullable id)responseObjectForResponse:(nullable NSURLResponse *)response
                           data:(nullable NSData *)data
                          error:(NSError * _Nullable __autoreleasing *)error NS_SWIFT_NOTHROW;
@end
```

原来就是这么一个协议方法，各种类型的responseSerializer类，都是遵守这个协议方法，实现了一个把我们请求到的data转换为我们需要的类型的数据的方法。至于各种类型的responseSerializer如何解析数据，我们到代理讲完再来补充。

-   这边还做了一个判断，如果自定义了GCD完成组`completionGroup`和完成队列的话`completionQueue`，会在加入这个组和在队列中回调Block。否则默认的是AF的创建的组：

```
static dispatch_group_t url_session_manager_completion_group() {
    static dispatch_group_t af_url_session_manager_completion_group;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        af_url_session_manager_completion_group = dispatch_group_create();
    });

    return af_url_session_manager_completion_group;
}
```

和主队列回调。**AF没有用这个GCD组做任何处理，只是提供这个接口，让我们有需求的自行调用处理。** 如果有对多个任务完成度的监听，可以自行处理。  
而队列的话，如果你不需要回调主线程，可以自己设置一个回调队列。

-   回到主线程，发送了任务完成的通知：

```
dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingTaskDidCompleteNotification object:task userInfo:userInfo];
            });
```

这个通知这回AF有用到了，在我们对UIKit的扩展中，用到了这个通知。

###### AF代理2：

**

```
- (void)URLSession:(__unused NSURLSession *)session
          dataTask:(__unused NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data
{
    //拼接数据
    [self.mutableData appendData:data];
}
```

同样被NSUrlSession代理转发到这里，拼接了需要回调的数据。

###### AF代理3：

**

```
- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location
{
    NSError *fileManagerError = nil;
    self.downloadFileURL = nil;

    //AF代理的自定义Block
    if (self.downloadTaskDidFinishDownloading) {
        //得到自定义下载路径
        self.downloadFileURL = self.downloadTaskDidFinishDownloading(session, downloadTask, location);
        
        if (self.downloadFileURL) {
            //把下载路径移动到我们自定义的下载路径
            [[NSFileManager defaultManager] moveItemAtURL:location toURL:self.downloadFileURL error:&fileManagerError];
            
            //错误发通知
            if (fileManagerError) {
                [[NSNotificationCenter defaultCenter] postNotificationName:AFURLSessionDownloadTaskDidFailToMoveFileNotification object:downloadTask userInfo:fileManagerError.userInfo];
            }
        }
    }
}
```

下载成功了被NSUrlSession代理转发到这里，这里有个地方需要注意下：

-   之前的NSUrlSession代理和这里都移动了文件到下载路径，而NSUrlSession代理的下载路径是所有request公用的下载路径，一旦设置，所有的request都会下载到之前那个路径。
-   而这个是对应的每个task的，每个task可以设置各自下载路径,还记得AFHttpManager的download方法么

**

```
 [manager downloadTaskWithRequest:resquest progress:nil destination:^NSURL * _Nonnull(NSURL * _Nonnull targetPath, NSURLResponse * _Nonnull response) {
    return path;
} completionHandler:^(NSURLResponse * _Nonnull response, NSURL * _Nullable filePath, NSError * _Nullable error) {
}];
```

这个地方return的path就是对应的这个代理方法里的path，我们调用最终会走到这么一个方法：

```
  - (void)addDelegateForDownloadTask:(NSURLSessionDownloadTask *)downloadTask
                          progress:(void (^)(NSProgress *downloadProgress)) downloadProgressBlock
                       destination:(NSURL * (^)(NSURL *targetPath, NSURLResponse *response))destination
                 completionHandler:(void (^)(NSURLResponse *response, NSURL *filePath, NSError *error))completionHandler
{
    AFURLSessionManagerTaskDelegate *delegate = [[AFURLSessionManagerTaskDelegate alloc] init];
    delegate.manager = self;
    delegate.completionHandler = completionHandler;

    //返回地址的Block
    if (destination) {
        
        //有点绕，就是把一个block赋值给我们代理的downloadTaskDidFinishDownloading，这个Block里的内部返回也是调用Block去获取到的，这里面的参数都是AF代理传过去的。
        delegate.downloadTaskDidFinishDownloading = ^NSURL * (NSURLSession * __unused session, NSURLSessionDownloadTask *task, NSURL *location) {
            //把Block返回的地址返回
            return destination(location, task.response);
        };
    }

    downloadTask.taskDescription = self.taskDescriptionForSessionTasks;

    [self setDelegate:delegate forTask:downloadTask];

    delegate.downloadProgressBlock = downloadProgressBlock;
}
```

清楚的可以看到地址被赋值给AF的Block了。

至此AF的代理也讲完了，**数据或错误信息随着AF代理成功失败回调，回到了用户的手中。**

  ### 接下来我们来补充之前`AFURLResponseSerialization`这一块是如何解析数据的
  
![image.jpeg](https://p6-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/dcc692ee47db402abe94140ee7ad275f~tplv-k3u1fbpfcp-watermark.image?)

如图所示，AF用来解析数据的一共上述这些方法。第一个实际是一个协议方法，协议方法如下：

```
@protocol AFURLResponseSerialization <NSObject, NSSecureCoding, NSCopying>

- (nullable id)responseObjectForResponse:(nullable NSURLResponse *)response
                           data:(nullable NSData *)data
                          error:(NSError * _Nullable __autoreleasing *)error;

@end
```

而后面6个类都是遵守这个协议方法，去做数据解析。**这地方可以再次感受一下AF的设计模式...** 接下来我们就来主要看看这些类对这个协议方法的实现：

###### AFHTTPResponseSerializer：

**

```
- (id)responseObjectForResponse:(NSURLResponse *)response
                           data:(NSData *)data
                          error:(NSError *__autoreleasing *)error
{
    [self validateResponse:(NSHTTPURLResponse *)response data:data error:error];
    return data;
}
```

-   方法调用了一个另外的方法之后，就把data返回来了，我们继续往里看这个方法：

```
// 判断是不是可接受类型和可接受code，不是则填充error
- (BOOL)validateResponse:(NSHTTPURLResponse *)response
                    data:(NSData *)data
                   error:(NSError * __autoreleasing *)error
{
    //response是否合法标识
    BOOL responseIsValid = YES;
    //验证的error
    NSError *validationError = nil;

    //如果存在且是NSHTTPURLResponse
    if (response && [response isKindOfClass:[NSHTTPURLResponse class]]) {
        
        //主要判断自己能接受的数据类型和response的数据类型是否匹配，
        //如果有接受数据类型，如果不匹配response，而且响应类型不为空，数据长度不为0
        if (self.acceptableContentTypes && ![self.acceptableContentTypes containsObject:[response MIMEType]] &&
            !([response MIMEType] == nil && [data length] == 0)) {
            
            //进入If块说明解析数据肯定是失败的，这时候要把解析错误信息放到error里。
            //如果数据长度大于0，而且有响应url
            if ([data length] > 0 && [response URL]) {
                
                //错误信息字典，填充一些错误信息
                NSMutableDictionary *mutableUserInfo = [@{
                                                          NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedStringFromTable(@"Request failed: unacceptable content-type: %@", @"AFNetworking", nil), [response MIMEType]],
                                                          NSURLErrorFailingURLErrorKey:[response URL],
                                                          AFNetworkingOperationFailingURLResponseErrorKey: response,
                                                        } mutableCopy];
                if (data) {
                    mutableUserInfo[AFNetworkingOperationFailingURLResponseDataErrorKey] = data;
                }

                //生成错误
                validationError = AFErrorWithUnderlyingError([NSError errorWithDomain:AFURLResponseSerializationErrorDomain code:NSURLErrorCannotDecodeContentData userInfo:mutableUserInfo], validationError);
            }
            
            //返回标识
            responseIsValid = NO;
        }

        //判断自己可接受的状态吗
        //如果和response的状态码不匹配，则进入if块
        if (self.acceptableStatusCodes && ![self.acceptableStatusCodes containsIndex:(NSUInteger)response.statusCode] && [response URL]) {
            //填写错误信息字典
            NSMutableDictionary *mutableUserInfo = [@{
                                               NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedStringFromTable(@"Request failed: %@ (%ld)", @"AFNetworking", nil), [NSHTTPURLResponse localizedStringForStatusCode:response.statusCode], (long)response.statusCode],
                                               NSURLErrorFailingURLErrorKey:[response URL],
                                               AFNetworkingOperationFailingURLResponseErrorKey: response,
                                       } mutableCopy];

            if (data) {
                mutableUserInfo[AFNetworkingOperationFailingURLResponseDataErrorKey] = data;
            }

            //生成错误
            validationError = AFErrorWithUnderlyingError([NSError errorWithDomain:AFURLResponseSerializationErrorDomain code:NSURLErrorBadServerResponse userInfo:mutableUserInfo], validationError);
            //返回标识
            responseIsValid = NO;
        }
    }

    //给我们传过来的错误指针赋值
    if (error && !responseIsValid) {
        *error = validationError;
    }

    //返回是否错误标识
    return responseIsValid;
}
```

-   看注释应该很容易明白这个方法有什么作用。简单来说，**这个方法就是来判断返回数据与咱们使用的解析器是否匹配，需要解析的状态码是否匹配。** 如果错误，则填充错误信息，并且返回NO，否则返回YES，错误信息为nil。
-   其中里面出现了两个属性值，一个`acceptableContentTypes`，一个`acceptableStatusCodes`，两者在初始化的时候有给默认值，我们也可以去自定义，但是如果给acceptableContentTypes定义了不匹配的类型，那么数据仍旧会解析错误。
-   而AFHTTPResponseSerializer仅仅是调用验证方法，然后就返回了data。

###### AFJSONResponseSerializer：

```
- (id)responseObjectForResponse:(NSURLResponse *)response
                           data:(NSData *)data
                          error:(NSError *__autoreleasing *)error
{
    //先判断是不是可接受类型和可接受code
    if (![self validateResponse:(NSHTTPURLResponse *)response data:data error:error]) {
        //error为空，或者有错误，去函数里判断。
        if (!error || AFErrorOrUnderlyingErrorHasCodeInDomain(*error, NSURLErrorCannotDecodeContentData, AFURLResponseSerializationErrorDomain)) {
            //返回空
            return nil;
        }
    }

    id responseObject = nil;
    NSError *serializationError = nil;
    // Workaround for behavior of Rails to return a single space for `head :ok` (a workaround for a bug in Safari), which is not interpreted as valid input by NSJSONSerialization.
    // See https://github.com/rails/rails/issues/1742
    
    //如果数据为空
    BOOL isSpace = [data isEqualToData:[NSData dataWithBytes:" " length:1]];
    //不空则去json解析
    if (data.length > 0 && !isSpace) {
        responseObject = [NSJSONSerialization JSONObjectWithData:data options:self.readingOptions error:&serializationError];
    } else {
        return nil;
    }

    //判断是否需要移除Null值
    if (self.removesKeysWithNullValues && responseObject) {
        responseObject = AFJSONObjectByRemovingKeysWithNullValues(responseObject, self.readingOptions);
    }
    
    //拿着json解析的error去填充错误信息
    if (error) {
        *error = AFErrorWithUnderlyingError(serializationError, *error);
    }

    //返回解析结果
    return responseObject;
}
```

注释写的很清楚，大概需要讲一下的是以下几个函数:

```
//1
AFErrorOrUnderlyingErrorHasCodeInDomain(*error, NSURLErrorCannotDecodeContentData, AFURLResponseSerializationErrorDomain))
//2
AFJSONObjectByRemovingKeysWithNullValues(responseObject, self.readingOptions);
//3
AFErrorWithUnderlyingError(serializationError, *error);
```

之前注释已经写清楚了这些函数的作用，首先来看第1个：

```
//判断是不是我们自己之前生成的错误信息，是的话返回YES
static BOOL AFErrorOrUnderlyingErrorHasCodeInDomain(NSError *error, NSInteger code, NSString *domain) {
    //判断错误域名和传过来的域名是否一致，错误code是否一致
    if ([error.domain isEqualToString:domain] && error.code == code) {
        return YES;
        
    }
    //如果userInfo的NSUnderlyingErrorKey有值，则在判断一次。
    else if (error.userInfo[NSUnderlyingErrorKey]) {
        return AFErrorOrUnderlyingErrorHasCodeInDomain(error.userInfo[NSUnderlyingErrorKey], code, domain);
    }

    return NO;
}
```

这里可以注意，我们这里传过去的code和domain两个参数分别为`NSURLErrorCannotDecodeContentData`、`AFURLResponseSerializationErrorDomain`，这两个参数是我们之前判断response可接受类型和code时候自己去生成错误的时候填写的。

第二个：

```
static id AFJSONObjectByRemovingKeysWithNullValues(id JSONObject, NSJSONReadingOptions readingOptions) {
    //分数组和字典
    if ([JSONObject isKindOfClass:[NSArray class]]) {
        
        //生成一个数组，只需要JSONObject.count个，感受到大神写代码的严谨态度了吗...
        NSMutableArray *mutableArray = [NSMutableArray arrayWithCapacity:[(NSArray *)JSONObject count]];
        for (id value in (NSArray *)JSONObject) {
            //调用自己
            [mutableArray addObject:AFJSONObjectByRemovingKeysWithNullValues(value, readingOptions)];
        }
        //看我们解析类型是mutable还是非muatable,返回mutableArray或者array
        return (readingOptions & NSJSONReadingMutableContainers) ? mutableArray : [NSArray arrayWithArray:mutableArray];
        
    } else if ([JSONObject isKindOfClass:[NSDictionary class]]) {
        NSMutableDictionary *mutableDictionary = [NSMutableDictionary dictionaryWithDictionary:JSONObject];
        for (id <NSCopying> key in [(NSDictionary *)JSONObject allKeys]) {
            id value = (NSDictionary *)JSONObject[key];
            //value空则移除
            if (!value || [value isEqual:[NSNull null]]) {
                [mutableDictionary removeObjectForKey:key];
            } else if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSDictionary class]]) {
                //如果数组还是去调用自己
                mutableDictionary[key] = AFJSONObjectByRemovingKeysWithNullValues(value, readingOptions);
            }
        }
        
        return (readingOptions & NSJSONReadingMutableContainers) ? mutableDictionary : [NSDictionary dictionaryWithDictionary:mutableDictionary];
    }

    return JSONObject;
}
```

方法主要还是通过递归的形式实现。比较简单。

第三个：

```
static NSError * AFErrorWithUnderlyingError(NSError *error, NSError *underlyingError) {
    if (!error) {
        return underlyingError;
    }

    if (!underlyingError || error.userInfo[NSUnderlyingErrorKey]) {
        return error;
    }
    NSMutableDictionary *mutableUserInfo = [error.userInfo mutableCopy];
    mutableUserInfo[NSUnderlyingErrorKey] = underlyingError;

    return [[NSError alloc] initWithDomain:error.domain code:error.code userInfo:mutableUserInfo];
}
```

方法主要是把json解析的错误，赋值给我们需要返回给用户的`error`上。比较简单，小伙伴们自己看看就好。

至此，AFJSONResponseSerializer就讲完了。  
而我们ResponseSerialize还有一些其他的类型解析，大家可以自行去阅读，代码还是很容易读的，在这里就不浪费篇幅去讲了。

### _AFURLSessionTaskSwizzling
在AFURLSessionManager中，有这么一个类：`_AFURLSessionTaskSwizzling`。这个类大概的作用就是替换掉`NSUrlSession`中的`resume`和`suspend`方法。正常处理原有逻辑的同时，多发送一个通知，以下是我们需要替换的新方法：

```

//被替换掉的方法，只要有TASK开启或者暂停，都会执行
- (void)af_resume {
    NSAssert([self respondsToSelector:@selector(state)], @"Does not respond to state");
    NSURLSessionTaskState state = [self state];
    [self af_resume];
    
    if (state != NSURLSessionTaskStateRunning) {
        [[NSNotificationCenter defaultCenter] postNotificationName:AFNSURLSessionTaskDidResumeNotification object:self];
    }
}
- (void)af_suspend {
    
    NSAssert([self respondsToSelector:@selector(state)], @"Does not respond to state");
    NSURLSessionTaskState state = [self state];
    [self af_suspend];
    
    if (state != NSURLSessionTaskStateSuspended) {
        [[NSNotificationCenter defaultCenter] postNotificationName:AFNSURLSessionTaskDidSuspendNotification object:self];
    }
}
```

这块知识是关于OC的Runtime:`method swizzling`的，如果有不清楚的地方，可以看看这里[method swizzling--by冰霜](https://www.jianshu.com/p/db6dc23834e3)或者自行查阅。

```
+ (void)load {
 
    if (NSClassFromString(@"NSURLSessionTask")) {
        
        // 1) 首先构建一个NSURLSession对象session，再通过session构建出一个_NSCFLocalDataTask变量

        NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        NSURLSession * session = [NSURLSession sessionWithConfiguration:configuration];
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wnonnull"
        NSURLSessionDataTask *localDataTask = [session dataTaskWithURL:nil];
#pragma clang diagnostic pop
        // 2) 获取到af_resume实现的指针
        IMP originalAFResumeIMP = method_getImplementation(class_getInstanceMethod([self class], @selector(af_resume)));
        Class currentClass = [localDataTask class];
        
        // 3) 检查当前class是否实现了resume。如果实现了，继续第4步。
        while (class_getInstanceMethod(currentClass, @selector(resume))) {
            
            // 4) 获取到当前class的父类（superClass）
            Class superClass = [currentClass superclass];
            
            // 5) 获取到当前class对于resume实现的指针
            IMP classResumeIMP = method_getImplementation(class_getInstanceMethod(currentClass, @selector(resume)));
            
            //  6) 获取到父类对于resume实现的指针
            IMP superclassResumeIMP = method_getImplementation(class_getInstanceMethod(superClass, @selector(resume)));
 
               // 7) 如果当前class对于resume的实现和父类不一样（类似iOS7上的情况），并且当前class的resume实现和af_resume不一样，才进行method swizzling。
            if (classResumeIMP != superclassResumeIMP &&
                originalAFResumeIMP != classResumeIMP) {
                //执行交换的函数
                [self swizzleResumeAndSuspendMethodForClass:currentClass];
            }
            // 8) 设置当前操作的class为其父类class，重复步骤3~8
            currentClass = [currentClass superclass];
        }
        
        [localDataTask cancel];
        [session finishTasksAndInvalidate];
    }
}
```

原方法中有大量的英文注释，我把它翻译过来如下：

> iOS 7和iOS 8在NSURLSessionTask实现上有些许不同，这使得下面的代码实现略显trick  
> 关于这个问题，大家做了很多Unit Test，足以证明这个方法是可行的  
> 目前我们所知的：

-   NSURLSessionTasks是一组class的统称，如果你仅仅使用提供的API来获取NSURLSessionTask的class，并不一定返回的是你想要的那个（获取NSURLSessionTask的class目的是为了获取其resume方法）
-   简单地使用[NSURLSessionTask class]并不起作用。你需要新建一个NSURLSession，并根据创建的session再构建出一个NSURLSessionTask对象才行。
-   iOS 7上，localDataTask（下面代码构造出的NSURLSessionDataTask类型的变量，为了获取对应Class）的类型是 __NSCFLocalDataTask，__NSCFLocalDataTask继承自__NSCFLocalSessionTask，__NSCFLocalSessionTask继承自__NSCFURLSessionTask。
-   iOS 8上，localDataTask的类型为__NSCFLocalDataTask，__NSCFLocalDataTask继承自__NSCFLocalSessionTask，__NSCFLocalSessionTask继承自NSURLSessionTask
-   iOS 7上，__NSCFLocalSessionTask和__NSCFURLSessionTask是仅有的两个实现了resume和suspend方法的类，另外__NSCFLocalSessionTask中的resume和suspend并没有调用其父类（即__NSCFURLSessionTask）方法，这也意味着两个类的方法都需要进行method swizzling。
-   iOS 8上，NSURLSessionTask是唯一实现了resume和suspend方法的类。这也意味着其是唯一需要进行method swizzling的类
-   因为NSURLSessionTask并不是在每个iOS版本中都存在，所以把这些放在此处（即load函数中），比如给一个dummy class添加swizzled方法都会变得很方便，管理起来也方便。

> 一些假设前提:

-   目前iOS中resume和suspend的方法实现中并没有调用对应的父类方法。如果日后iOS改变了这种做法，我们还需要重新处理。
-   没有哪个后台task会重写resume和suspend函数

其余的一部分翻译在注释中，对应那一行代码。大概总结下这个注释：

-   其实这是被社区大量讨论的一个bug，之前AF因为这个替换方法，会导致偶发性的crash，如果不要这个swizzle则问题不会再出现，但是这样会导致AF中很多UIKit的扩展都不能正常使用。
-   **原来这是因为iOS7和iOS8的NSURLSessionTask的继承链不同导致的，** 而且在iOS7继承链中会有两个类都实现了`resume`和`suspend`方法。而且子类没有调用父类的方法，我们则需要对着两个类都进行方法替换。而iOS8只需要对一个类进行替换。
-   对着注释看，上述方法代码不难理解，用一个while循环，一级一级去获取父类，如果实现了`resume`方法，则进行替换。

但是有几个点大家可能会觉得疑惑的，我们先把这个方法调用的替换的函数一块贴出来。

**

```
//其引用的交换的函数：
+ (void)swizzleResumeAndSuspendMethodForClass:(Class)theClass {
    Method afResumeMethod = class_getInstanceMethod(self, @selector(af_resume));
    Method afSuspendMethod = class_getInstanceMethod(self, @selector(af_suspend));

    if (af_addMethod(theClass, @selector(af_resume), afResumeMethod)) {
        af_swizzleSelector(theClass, @selector(resume), @selector(af_resume));
    }

    if (af_addMethod(theClass, @selector(af_suspend), afSuspendMethod)) {
        af_swizzleSelector(theClass, @selector(suspend), @selector(af_suspend));
    }
}
static inline void af_swizzleSelector(Class theClass, SEL originalSelector, SEL swizzledSelector) {
    Method originalMethod = class_getInstanceMethod(theClass, originalSelector);
    Method swizzledMethod = class_getInstanceMethod(theClass, swizzledSelector);
    method_exchangeImplementations(originalMethod, swizzledMethod);
}
static inline BOOL af_addMethod(Class theClass, SEL selector, Method method) {
    return class_addMethod(theClass, selector,  method_getImplementation(method),  method_getTypeEncoding(method));
}
```

因为有小伙伴问到过，所以我们来分析分析大家可能会觉得疑惑的地方：

1.  首先可以注意`class_getInstanceMethod`这个方法，它会获取到当前类继承链逐级往上，第一个实现的该方法。所以说它获取到的方法不能确定是当前类还是父类的。而且这里也没有用dispatch_once_t来保证一个方法只交换一次，那万一这是父类的方法，当前类换一次，父类又换一次，不是等于没交换么？...请注意这行判断：

```
// 7) 如果当前class对于resume的实现和父类不一样（类似iOS7上的情况），并且当前class的resume实现和af_resume不一样，才进行method swizzling。
if (classResumeIMP != superclassResumeIMP && originalAFResumeIMP != classResumeIMP) { 
          //执行交换的函数
         [self swizzleResumeAndSuspendMethodForClass:currentClass]; 
}
```

这个条件就杜绝了这种情况的发生，只有当前类实现了这个方法，才可能进入这个if块。

2.那iOS7两个类都交换了`af_resume`，那岂不是父类换到子类方法了?...只能说又是没仔细看代码的...注意AF是去向当前类添加`af_resume`方法，然后去交换当前类的`af_resume`。所以说根本不会出现这种情况...

`AFUrlSessionManager` 基本上就这么多内容了。


### maxConcurrentOperationCount = 1
现在我们回到一开始初始化的这行代码上:

```
self.operationQueue.maxConcurrentOperationCount = 1;
```

1）首先我们要明确一个概念，这里的并发数仅仅是回调代理的线程并发数。而不是请求网络的线程并发数。请求网络是由NSUrlSession来做的，它内部维护了一个线程池，用来做网络请求。它调度线程,基于底层的CFSocket去发送请求和接收数据。这些**线程是并发的**。

2）明确了这个概念之后，我们来梳理一下AF3.x的整个流程和线程的关系：

-   我们一开始初始化`sessionManager`的时候，一般都是在主线程，（当然不排除有些人喜欢在分线程初始化...）
-   然后我们调用`get`或者`post`等去请求数据，接着会进行`request`拼接，AF代理的字典映射，`progress`的`KVO`添加等等，到`NSUrlSession`的`resume`之前这些准备工作，仍旧是在主线程中的。
-   然后我们调用`NSUrlSession`的`resume`，接着就跑到`NSUrlSession`内部去对网络进行数据请求了,在它内部是多线程并发的去请求数据的。
-   紧接着数据请求完成后，回调回来在我们一开始生成的并发数为1的`NSOperationQueue`中，这个时候会是多线程串行的回调回来的。（注：不明白的朋友可以看看雷纯峰大神这篇[iOS 并发编程之 Operation Queues](https://link.jianshu.com/?t=http://blog.leichunfeng.com/blog/2015/07/29/ios-concurrency-programming-operation-queues/)）
-   然后我们到返回数据解析那一块，我们自己又创建了并发的多线程，去对这些数据进行了各种类型的解析。
-   最后我们如果有自定义的`completionQueue`，则在自定义的`queue`中回调回来，也就是分线程回调回来，否则就是主队列，主线程中回调结束。

3）最后我们来解释解释为什么回调Queue要设置并发数为1：

-   我认为AF这么做有以下两点原因：  
    1）众所周知，AF2.x所有的回调是在一条线程，这条线程是AF的常驻线程，而这一条线程正是AF调度request的思想精髓所在，所以第一个目的就是为了和之前版本保持一致。  
    2）因为跟代理相关的一些操作AF都使用了NSLock。所以就算Queue的并发数设置为n，因为多线程回调，锁的等待，导致所提升的程序速度也并不明显。**反而多task回调导致的多线程并发，平白浪费了部分性能。**  
    而设置Queue的并发数为1，（注：这里虽然回调Queue的并发数为1，仍然会有不止一条线程，但是因为是串行回调，所以同一时间，只会有一条线程在操作AFUrlSessionManager的那些方法。）至少回调的事件，是不需要多线程并发的。**回调没有了NSLock的等待时间，所以对时间并没有多大的影响。** （注：但是还是会有多线程的操作的，因为设置刚开始调起请求的时候，是在主线程的，而回调则是串行分线程。）

当然这仅仅是我个人的看法，如果有不同意见的欢迎交流~

至此我们AF3.X业务层的逻辑，基本上结束了。小伙伴们，看到这你明白了AF做了什么了吗？可能很多朋友要扔鸡蛋了...可能你还是没觉得AF到底有什么用，我用NSUrlSession不也一样，我干嘛要用AF，在这里，我暂时卖个关子，等我们下篇讲完`AFSecurityPolicy`和部分`UIKit`的扩展，以及AF2.x的核心类源码实现之后，我们再好好总结。


# AFNetworking之于https认证
简单的理解下https：**https在http请求的基础上多加了一个证书认证的流程。** 认证通过之后，数据传输都是加密进行的。  
关于https的更多概念，我就不赘述了，网上有大量的文章，小伙伴们可以自行查阅。在这里大概的讲讲https的认证过程吧，如下图所示：

![image.jpeg](https://p6-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/bf50eff4d87e4ee4af4a2a40c5e0dd71~tplv-k3u1fbpfcp-watermark.image?)

**1. 客户端发起HTTPS请求**  
　　这个没什么好说的，就是用户在浏览器里输入一个https网址，然后连接到server的443端口。  
**2. 服务端的配置**  
　　采用HTTPS协议的服务器必须要有一套数字证书，可以自己制作，也可以向组织申请。区别就是自己颁发的证书需要客户端验证通过，才可以继续访问，而使用受信任的公司申请的证书则不会弹出提示页面。这套证书其实就是一对公钥和私钥。如果对公钥和私钥不太理解，可以想象成一把钥匙和一个锁头，只是全世界只有你一个人有这把钥匙，你可以把锁头给别人，别人可以用这个锁把重要的东西锁起来，然后发给你，因为只有你一个人有这把钥匙，所以只有你才能看到被这把锁锁起来的东西。  
**3. 传送证书**  
　　这个证书其实就是公钥，只是包含了很多信息，如证书的颁发机构，过期时间等等。  
**4. 客户端解析证书**  
　　这部分工作是有客户端的TLS/SSL来完成的，首先会验证公钥是否有效，比如颁发机构，过期时间等等，如果发现异常，则会弹出一个警告框，提示证书存在问题。如果证书没有问题，那么就生成一个随机值。然后用证书对该随机值进行加密。就好像上面说的，把随机值用锁头锁起来，这样除非有钥匙，不然看不到被锁住的内容。  
**5. 传送加密信息**  
　　这部分传送的是用证书加密后的随机值，目的就是让服务端得到这个随机值，以后客户端和服务端的通信就可以通过这个随机值来进行加密解密了。  
**6. 服务段解密信息**  
　　服务端用私钥解密后，得到了客户端传过来的随机值(私钥)，然后把内容通过该值进行对称加密。所谓对称加密就是，将信息和私钥通过某种算法混合在一起，这样除非知道私钥，不然无法获取内容，而正好客户端和服务端都知道这个私钥，所以只要加密算法够彪悍，私钥够复杂，数据就够安全。  
**7. 传输加密后的信息**  
　　这部分信息是服务段用私钥加密后的信息，可以在客户端被还原。  
**8. 客户端解密信息**  
　　客户端用之前生成的私钥解密服务段传过来的信息，于是获取了解密后的内容。整个过程第三方即使监听到了数据，也束手无策。

这就是整个https验证的流程了。简单总结一下：

-   就是用户发起请求，服务器响应后返回一个证书，证书中包含一些基本信息和公钥。
-   用户拿到证书后，去验证这个证书是否合法，不合法，则请求终止。
-   合法则生成一个随机数，作为对称加密的密钥，用服务器返回的公钥对这个随机数加密。然后返回给服务器。
-   服务器拿到加密后的随机数，利用私钥解密，然后再用解密后的随机数（对称密钥），把需要返回的数据加密，加密完成后数据传输给用户。
-   最后用户拿到加密的数据，用一开始的那个随机数（对称密钥），进行数据解密。整个过程完成。

当然这仅仅是一个单向认证，https还会有双向认证，相对于单向认证也很简单。仅仅多了服务端验证客户端这一步。感兴趣的可以看看这篇：[Https单向认证和双向认证。](https://link.jianshu.com/?t=http://blog.csdn.net/duanbokan/article/details/50847612)

###### 了解了https认证流程后，接下来我们来讲讲AFSecurityPolicy这个类，AF就是用这个类来满足我们各种https认证需求。

在这之前我们来看看AF用来做https认证的代理：

```
- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler
{
    //挑战处理类型为 默认
    /*
     NSURLSessionAuthChallengePerformDefaultHandling：默认方式处理
     NSURLSessionAuthChallengeUseCredential：使用指定的证书
     NSURLSessionAuthChallengeCancelAuthenticationChallenge：取消挑战
     */
    NSURLSessionAuthChallengeDisposition disposition = NSURLSessionAuthChallengePerformDefaultHandling;
    __block NSURLCredential *credential = nil;

    // sessionDidReceiveAuthenticationChallenge是自定义方法，用来如何应对服务器端的认证挑战

    if (self.sessionDidReceiveAuthenticationChallenge) {
        disposition = self.sessionDidReceiveAuthenticationChallenge(session, challenge, &credential);
    } else {
         // 此处服务器要求客户端的接收认证挑战方法是NSURLAuthenticationMethodServerTrust
        // 也就是说服务器端需要客户端返回一个根据认证挑战的保护空间提供的信任（即challenge.protectionSpace.serverTrust）产生的挑战证书。
       
        // 而这个证书就需要使用credentialForTrust:来创建一个NSURLCredential对象
        if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
            
            // 基于客户端的安全策略来决定是否信任该服务器，不信任的话，也就没必要响应挑战
            if ([self.securityPolicy evaluateServerTrust:challenge.protectionSpace.serverTrust forDomain:challenge.protectionSpace.host]) {
                // 创建挑战证书（注：挑战方式为UseCredential和PerformDefaultHandling都需要新建挑战证书）
                credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
                // 确定挑战的方式
                if (credential) {
                    //证书挑战  设计policy,none，则跑到这里
                    disposition = NSURLSessionAuthChallengeUseCredential;
                } else {
                    disposition = NSURLSessionAuthChallengePerformDefaultHandling;
                }
            } else {
                //取消挑战
                disposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;
            }
        } else {
            //默认挑战方式
            disposition = NSURLSessionAuthChallengePerformDefaultHandling;
        }
    }
    //完成挑战
    if (completionHandler) {
        completionHandler(disposition, credential);
    }
}
```

更多的这个方法的细节问题，可以看注释，或者查阅楼主之前的相关文章，都有去讲到这个代理方法。在这里我们大概的讲讲这个方法做了什么：  
1）首先指定了https为默认的认证方式。  
2）判断有没有自定义Block:`sessionDidReceiveAuthenticationChallenge`，有的话，使用我们自定义Block,生成一个认证方式，并且可以给`credential`赋值，即我们需要接受认证的证书。然后直接调用`completionHandler`，去根据这两个参数，执行系统的认证。至于这个系统的认证到底做了什么，可以看文章最后，这里暂且略过。  
3）如果没有自定义Block，我们判断如果服务端的认证方法要求是`NSURLAuthenticationMethodServerTrust`,**则只需要验证服务端证书是否安全**（即https的单向认证，这是AF默认处理的认证方式，其他的认证方式，只能由我们自定义Block的实现）  
4）接着我们就执行了`AFSecurityPolicy`相关的一个方法，做了一个AF内部的一个https认证：

```
[self.securityPolicy evaluateServerTrust:challenge.protectionSpace.serverTrust forDomain:challenge.protectionSpace.host])
```

AF默认的处理是，如果这行返回NO、说明AF内部认证失败，则取消https认证，即取消请求。返回YES则进入if块，用服务器返回的一个`serverTrust`去生成了一个认证证书。（注：这个`serverTrust`是服务器传过来的，里面包含了服务器的证书信息，是用来我们本地客户端去验证该证书是否合法用的，后面会更详细的去讲这个参数）然后如果有证书，则用证书认证方式，否则还是用默认的验证方式。最后调用`completionHandler`传递认证方式和要认证的证书，去做系统根证书验证。

-   总结一下这里`securityPolicy`存在的作用就是，**使得在系统底层自己去验证之前，AF可以先去验证服务端的证书。** 如果通不过，则直接越过系统的验证，取消https的网络请求。否则，继续去走系统根证书的验证。

###### 接下来我们看看`AFSecurityPolicy`内部是如果做https认证的:

如下方式，我们可以创建一个`securityPolicy`：

```
AFSecurityPolicy *policy = [AFSecurityPolicy defaultPolicy];
```

内部创建：

```
+ (instancetype)defaultPolicy {
    AFSecurityPolicy *securityPolicy = [[self alloc] init];
    securityPolicy.SSLPinningMode = AFSSLPinningModeNone;
    return securityPolicy;
}
```

默认指定了一个`SSLPinningMode`模式为`AFSSLPinningModeNone`。  
对于AFSecurityPolicy，一共有4个重要的属性：

**

```
//https验证模式
@property (readonly, nonatomic, assign) AFSSLPinningMode SSLPinningMode;
//可以去匹配服务端证书验证的证书
@property (nonatomic, strong, nullable) NSSet <NSData *> *pinnedCertificates;
//是否支持非法的证书（例如自签名证书）
@property (nonatomic, assign) BOOL allowInvalidCertificates;
//是否去验证证书域名是否匹配
@property (nonatomic, assign) BOOL validatesDomainName;
```

它们的作用我添加在注释里了，第一条就是`AFSSLPinningMode`, 共提供了3种验证方式：

**

```
typedef NS_ENUM(NSUInteger, AFSSLPinningMode) {
    //不验证
    AFSSLPinningModeNone,
    //只验证公钥
    AFSSLPinningModePublicKey,
    //验证证书
    AFSSLPinningModeCertificate,
};
```

我们接着回到代理https认证的这行代码上：

```
[self.securityPolicy evaluateServerTrust:challenge.protectionSpace.serverTrust forDomain:challenge.protectionSpace.host]
```

-   我们传了两个参数进去，一个是`SecTrustRef`类型的serverTrust，这是什么呢？我们看到苹果的文档介绍如下：

> CFType used for performing X.509 certificate trust evaluations.

大概意思是用于执行X。509证书信任评估，  
再讲简单点，其实就是一个容器，装了服务器端需要验证的证书的基本信息、公钥等等，不仅如此，它还可以装一些评估策略，还有客户端的锚点证书，这个客户端的证书，可以用来和服务端的证书去匹配验证的。

-   除此之外还把服务器域名传了过去。

我们来到这个方法，代码如下：

```
//验证服务端是否值得信任
- (BOOL)evaluateServerTrust:(SecTrustRef)serverTrust
                  forDomain:(NSString *)domain
{
    //判断矛盾的条件
    //判断有域名，且允许自建证书，需要验证域名，
    //因为要验证域名，所以必须不能是后者两种：AFSSLPinningModeNone或者添加到项目里的证书为0个。
    if (domain && self.allowInvalidCertificates && self.validatesDomainName && (self.SSLPinningMode == AFSSLPinningModeNone || [self.pinnedCertificates count] == 0)) {
        // https://developer.apple.com/library/mac/documentation/NetworkingInternet/Conceptual/NetworkingTopics/Articles/OverridingSSLChainValidationCorrectly.html
        //  According to the docs, you should only trust your provided certs for evaluation.
        //  Pinned certificates are added to the trust. Without pinned certificates,
        //  there is nothing to evaluate against.
        //
        //  From Apple Docs:
        //          "Do not implicitly trust self-signed certificates as anchors (kSecTrustOptionImplicitAnchors).
        //           Instead, add your own (self-signed) CA certificate to the list of trusted anchors."
        NSLog(@"In order to validate a domain name for self signed certificates, you MUST use pinning.");
        //不受信任，返回
        return NO;
    }

    //用来装验证策略
    NSMutableArray *policies = [NSMutableArray array];
    //要验证域名
    if (self.validatesDomainName) {
        
        // 如果需要验证domain，那么就使用SecPolicyCreateSSL函数创建验证策略，其中第一个参数为true表示验证整个SSL证书链，第二个参数传入domain，用于判断整个证书链上叶子节点表示的那个domain是否和此处传入domain一致
        //添加验证策略
        [policies addObject:(__bridge_transfer id)SecPolicyCreateSSL(true, (__bridge CFStringRef)domain)];
    } else {
        // 如果不需要验证domain，就使用默认的BasicX509验证策略
        [policies addObject:(__bridge_transfer id)SecPolicyCreateBasicX509()];
    }
    
    //serverTrust：X。509服务器的证书信任。
    // 为serverTrust设置验证策略，即告诉客户端如何验证serverTrust
    SecTrustSetPolicies(serverTrust, (__bridge CFArrayRef)policies);

    
    //有验证策略了，可以去验证了。如果是AFSSLPinningModeNone，是自签名，直接返回可信任，否则不是自签名的就去系统根证书里去找是否有匹配的证书。
    if (self.SSLPinningMode == AFSSLPinningModeNone) {
        //如果支持自签名，直接返回YES,不允许才去判断第二个条件，判断serverTrust是否有效
        return self.allowInvalidCertificates || AFServerTrustIsValid(serverTrust);
    }
    //如果验证无效AFServerTrustIsValid，而且allowInvalidCertificates不允许自签，返回NO
    else if (!AFServerTrustIsValid(serverTrust) && !self.allowInvalidCertificates) {
        return NO;
    }

    //判断SSLPinningMode
    switch (self.SSLPinningMode) {
        // 理论上，上面那个部分已经解决了self.SSLPinningMode)为AFSSLPinningModeNone)等情况，所以此处再遇到，就直接返回NO
        case AFSSLPinningModeNone:
        default:
            return NO;
        
        //验证证书类型
        case AFSSLPinningModeCertificate: {
            
            NSMutableArray *pinnedCertificates = [NSMutableArray array];
            
            //把证书data，用系统api转成 SecCertificateRef 类型的数据,SecCertificateCreateWithData函数对原先的pinnedCertificates做一些处理，保证返回的证书都是DER编码的X.509证书

            for (NSData *certificateData in self.pinnedCertificates) {
                [pinnedCertificates addObject:(__bridge_transfer id)SecCertificateCreateWithData(NULL, (__bridge CFDataRef)certificateData)];
            }
            // 将pinnedCertificates设置成需要参与验证的Anchor Certificate（锚点证书，通过SecTrustSetAnchorCertificates设置了参与校验锚点证书之后，假如验证的数字证书是这个锚点证书的子节点，即验证的数字证书是由锚点证书对应CA或子CA签发的，或是该证书本身，则信任该证书），具体就是调用SecTrustEvaluate来验证。
            //serverTrust是服务器来的验证，有需要被验证的证书。
            SecTrustSetAnchorCertificates(serverTrust, (__bridge CFArrayRef)pinnedCertificates);

            //自签在之前是验证通过不了的，在这一步，把我们自己设置的证书加进去之后，就能验证成功了。
            
            //再去调用之前的serverTrust去验证该证书是否有效，有可能：经过这个方法过滤后，serverTrust里面的pinnedCertificates被筛选到只有信任的那一个证书
            if (!AFServerTrustIsValid(serverTrust)) {
                return NO;
            }

            // obtain the chain after being validated, which *should* contain the pinned certificate in the last position (if it's the Root CA)
            //注意，这个方法和我们之前的锚点证书没关系了，是去从我们需要被验证的服务端证书，去拿证书链。
            // 服务器端的证书链，注意此处返回的证书链顺序是从叶节点到根节点
            NSArray *serverCertificates = AFCertificateTrustChainForServerTrust(serverTrust);
            
            //reverseObjectEnumerator逆序
            for (NSData *trustChainCertificate in [serverCertificates reverseObjectEnumerator]) {
                
                //如果我们的证书中，有一个和它证书链中的证书匹配的，就返回YES
                if ([self.pinnedCertificates containsObject:trustChainCertificate]) {
                    return YES;
                }
            }
            //没有匹配的
            return NO;
        }
            //公钥验证 AFSSLPinningModePublicKey模式同样是用证书绑定(SSL Pinning)方式验证，客户端要有服务端的证书拷贝，只是验证时只验证证书里的公钥，不验证证书的有效期等信息。只要公钥是正确的，就能保证通信不会被窃听，因为中间人没有私钥，无法解开通过公钥加密的数据。
        case AFSSLPinningModePublicKey: {
            
            NSUInteger trustedPublicKeyCount = 0;
            
            // 从serverTrust中取出服务器端传过来的所有可用的证书，并依次得到相应的公钥
            NSArray *publicKeys = AFPublicKeyTrustChainForServerTrust(serverTrust);

            //遍历服务端公钥
            for (id trustChainPublicKey in publicKeys) {
                //遍历本地公钥
                for (id pinnedPublicKey in self.pinnedPublicKeys) {
                    //判断如果相同 trustedPublicKeyCount+1
                    if (AFSecKeyIsEqualToKey((__bridge SecKeyRef)trustChainPublicKey, (__bridge SecKeyRef)pinnedPublicKey)) {
                        trustedPublicKeyCount += 1;
                    }
                }
            }
            return trustedPublicKeyCount > 0;
        }
    }
    
    return NO;
}
```

代码的注释很多，这一块确实比枯涩，大家可以参照着源码一起看，加深理解。

-   这个方法是`AFSecurityPolicy`最核心的方法，其他的都是为了配合这个方法。这个方法完成了服务端的证书的信任评估。我们总结一下这个方法做了什么（细节可以看注释）：

1.  根据模式，如果是`AFSSLPinningModeNone`，则肯定是返回YES，不论是自签还是公信机构的证书。
1.  如果是`AFSSLPinningModeCertificate`，则从`serverTrust`中去获取证书链，然后和我们一开始初始化设置的证书集合`self.pinnedCertificates`去匹配，**如果有一对能匹配成功的，就返回YES，否则NO。**  
    看到这可能有小伙伴要问了，什么是证书链？下面这段是我从百科上摘来的:

> 证书链由两个环节组成—信任锚（CA 证书）环节和已签名证书环节。自我签名的证书仅有一个环节的长度—信任锚环节就是已签名证书本身。

简单来说，证书链就是就是根证书，和根据根证书签名派发得到的证书。

3.  如果是`AFSSLPinningModePublicKey`公钥验证，则和第二步一样还是从`serverTrust`，获取证书链每一个证书的公钥，放到数组中。和我们的`self.pinnedPublicKeys`，去配对，如果有一个相同的，就返回YES，否则NO。至于这个`self.pinnedPublicKeys`,初始化的地方如下：

```
  //设置证书数组
   - (void)setPinnedCertificates:(NSSet *)pinnedCertificates {
    
    _pinnedCertificates = pinnedCertificates;

    //获取对应公钥集合
    if (self.pinnedCertificates) {
        //创建公钥集合
        NSMutableSet *mutablePinnedPublicKeys = [NSMutableSet setWithCapacity:[self.pinnedCertificates count]];
        //从证书中拿到公钥。
        for (NSData *certificate in self.pinnedCertificates) {
            id publicKey = AFPublicKeyForCertificate(certificate);
            if (!publicKey) {
                continue;
            }
            [mutablePinnedPublicKeys addObject:publicKey];
        }
        self.pinnedPublicKeys = [NSSet setWithSet:mutablePinnedPublicKeys];
    } else {
        self.pinnedPublicKeys = nil;
    }
}
```

AF复写了设置证书的set方法，并同时把证书中每个公钥放在了self.pinnedPublicKeys中。

这个方法中关联了一系列的函数，我在这边按照调用顺序一一列出来（有些是系统函数，不在这里列出，会在下文集体描述作用）：

###### 函数一：AFServerTrustIsValid

```
//判断serverTrust是否有效
static BOOL AFServerTrustIsValid(SecTrustRef serverTrust) {
    
    //默认无效
    BOOL isValid = NO;
    //用来装验证结果，枚举
    SecTrustResultType result;  
      
    //__Require_noErr_Quiet 用来判断前者是0还是非0，如果0则表示没错，就跳到后面的表达式所在位置去执行，否则表示有错就继续往下执行。
  
    //SecTrustEvaluate系统评估证书的是否可信的函数，去系统根目录找，然后把结果赋值给result。评估结果匹配，返回0，否则出错返回非0
    //do while 0 ,只执行一次，为啥要这样写....
    __Require_noErr_Quiet(SecTrustEvaluate(serverTrust, &result), _out);

    //评估没出错走掉这，只有两种结果能设置为有效，isValid= 1
    //当result为kSecTrustResultUnspecified（此标志表示serverTrust评估成功，此证书也被暗中信任了，但是用户并没有显示地决定信任该证书）。
    //或者当result为kSecTrustResultProceed（此标志表示评估成功，和上面不同的是该评估得到了用户认可），这两者取其一就可以认为对serverTrust评估成功
    isValid = (result == kSecTrustResultUnspecified || result == kSecTrustResultProceed);

    //out函数块,如果为SecTrustEvaluate，返回非0，则评估出错，则isValid为NO
_out:
    return isValid;
}
```

-   这个方法用来验证serverTrust是否有效，其中主要是交由系统API`SecTrustEvaluate`来验证的，它验证完之后会返回一个`SecTrustResultType`枚举类型的result，然后我们根据这个result去判断是否证书是否有效。
-   其中比较有意思的是，它调用了一个系统定义的宏函数`__Require_noErr_Quiet`，函数定义如下：

```
#ifndef __Require_noErr_Quiet
    #define __Require_noErr_Quiet(errorCode, exceptionLabel)                      \
      do                                                                          \
      {                                                                           \
          if ( __builtin_expect(0 != (errorCode), 0) )                            \
          {                                                                       \
              goto exceptionLabel;                                                \
          }                                                                       \
      } while ( 0 )
#endif
```

这个函数主要作用就是，判断errorCode是否为0，不为0则，程序用`goto`跳到`exceptionLabel`位置去执行。这个`exceptionLabel`就是一个代码位置标识，类似上面的`_out`。  
说它有意思的地方是在于，它用了一个do...while(0)循环，循环条件为0，也就是只执行一次循环就结束。对这么做的原因，楼主百思不得其解...看来系统原生API更是高深莫测...经冰霜大神的提醒，这么做是为了适配早期的API??!

###### 函数二、三（两个函数类似，所以放在一起）：获取serverTrust证书链证书，获取serverTrust证书链公钥

```
//获取证书链
static NSArray * AFCertificateTrustChainForServerTrust(SecTrustRef serverTrust) {
    //使用SecTrustGetCertificateCount函数获取到serverTrust中需要评估的证书链中的证书数目，并保存到certificateCount中
    CFIndex certificateCount = SecTrustGetCertificateCount(serverTrust);
    //创建数组
    NSMutableArray *trustChain = [NSMutableArray arrayWithCapacity:(NSUInteger)certificateCount];

    //// 使用SecTrustGetCertificateAtIndex函数获取到证书链中的每个证书，并添加到trustChain中，最后返回trustChain
    for (CFIndex i = 0; i < certificateCount; i++) {
        SecCertificateRef certificate = SecTrustGetCertificateAtIndex(serverTrust, i);
        [trustChain addObject:(__bridge_transfer NSData *)SecCertificateCopyData(certificate)];
    }

    return [NSArray arrayWithArray:trustChain];
}
```
```

// 从serverTrust中取出服务器端传过来的所有可用的证书，并依次得到相应的公钥
static NSArray * AFPublicKeyTrustChainForServerTrust(SecTrustRef serverTrust) {
    
    // 接下来的一小段代码和上面AFCertificateTrustChainForServerTrust函数的作用基本一致，都是为了获取到serverTrust中证书链上的所有证书，并依次遍历，取出公钥。
    //安全策略
    SecPolicyRef policy = SecPolicyCreateBasicX509();
    CFIndex certificateCount = SecTrustGetCertificateCount(serverTrust);
    NSMutableArray *trustChain = [NSMutableArray arrayWithCapacity:(NSUInteger)certificateCount];
    //遍历serverTrust里证书的证书链。
    for (CFIndex i = 0; i < certificateCount; i++) {
        //从证书链取证书
        SecCertificateRef certificate = SecTrustGetCertificateAtIndex(serverTrust, i);
        //数组
        SecCertificateRef someCertificates[] = {certificate};
        //CF数组
        CFArrayRef certificates = CFArrayCreate(NULL, (const void **)someCertificates, 1, NULL);

        SecTrustRef trust;
        
        // 根据给定的certificates和policy来生成一个trust对象
        //不成功跳到 _out。
        __Require_noErr_Quiet(SecTrustCreateWithCertificates(certificates, policy, &trust), _out);

        SecTrustResultType result;
        
        // 使用SecTrustEvaluate来评估上面构建的trust
        //评估失败跳到 _out
        __Require_noErr_Quiet(SecTrustEvaluate(trust, &result), _out);

        // 如果该trust符合X.509证书格式，那么先使用SecTrustCopyPublicKey获取到trust的公钥，再将此公钥添加到trustChain中
        [trustChain addObject:(__bridge_transfer id)SecTrustCopyPublicKey(trust)];

    _out:
        //释放资源
        if (trust) {
            CFRelease(trust);
        }

        if (certificates) {
            CFRelease(certificates);
        }
    
        continue;
    }
    CFRelease(policy);

    // 返回对应的一组公钥
    return [NSArray arrayWithArray:trustChain];
}
```

两个方法功能类似，都是调用了一些系统的API，利用For循环，获取证书链上每一个证书或者公钥。具体内容看源码很好理解。唯一需要注意的是，这个获取的证书排序，是从证书链的叶节点，到根节点的。

###### 函数四：判断公钥是否相同

```
//判断两个公钥是否相同
static BOOL AFSecKeyIsEqualToKey(SecKeyRef key1, SecKeyRef key2) {
    
#if TARGET_OS_IOS || TARGET_OS_WATCH || TARGET_OS_TV
    //iOS 判断二者地址
    return [(__bridge id)key1 isEqual:(__bridge id)key2];
#else
    return [AFSecKeyGetData(key1) isEqual:AFSecKeyGetData(key2)];
#endif
}
```

方法适配了各种运行环境，做了匹配的判断。

###### 接下来列出验证过程中调用过得系统原生函数：

```
//1.创建一个验证SSL的策略，两个参数，第一个参数true则表示验证整个证书链
//第二个参数传入domain，用于判断整个证书链上叶子节点表示的那个domain是否和此处传入domain一致
SecPolicyCreateSSL(<#Boolean server#>, <#CFStringRef  _Nullable hostname#>)
SecPolicyCreateBasicX509();
//2.默认的BasicX509验证策略,不验证域名。
SecPolicyCreateBasicX509();
//3.为serverTrust设置验证策略，即告诉客户端如何验证serverTrust
SecTrustSetPolicies(<#SecTrustRef  _Nonnull trust#>, <#CFTypeRef  _Nonnull policies#>)
//4.验证serverTrust,并且把验证结果返回给第二参数 result
SecTrustEvaluate(<#SecTrustRef  _Nonnull trust#>, <#SecTrustResultType * _Nullable result#>)
//5.判断前者errorCode是否为0，为0则跳到exceptionLabel处执行代码
__Require_noErr(<#errorCode#>, <#exceptionLabel#>)
//6.根据证书data,去创建SecCertificateRef类型的数据。
SecCertificateCreateWithData(<#CFAllocatorRef  _Nullable allocator#>, <#CFDataRef  _Nonnull data#>)
//7.给serverTrust设置锚点证书，即如果以后再次去验证serverTrust，会从锚点证书去找是否匹配。
SecTrustSetAnchorCertificates(serverTrust, (__bridge CFArrayRef)pinnedCertificates);
//8.拿到证书链中的证书个数
CFIndex certificateCount = SecTrustGetCertificateCount(serverTrust);
//9.去取得证书链中对应下标的证书。
SecTrustGetCertificateAtIndex(serverTrust, i)
//10.根据证书获取公钥。
SecTrustCopyPublicKey(trust)
```
可能看到这，又有些小伙伴迷糊了，讲了这么多，**那如果做https请求，真正需要我们自己做的到底是什么呢？** 这里来解答一下，分为以下两种情况：

1.  如果你用的是付费的公信机构颁发的证书，标准的https，**那么无论你用的是AF还是NSUrlSession,什么都不用做，代理方法也不用实现。** 你的网络请求就能正常完成。
1.  如果你用的是自签名的证书:

-   首先你需要在plist文件中，设置可以返回不安全的请求（关闭该域名的ATS）。
-   其次，如果是`NSUrlSesion`，那么需要在代理方法实现如下：

```
    - (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler
 {
          __block NSURLCredential *credential = nil;

        credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust]; 
        // 确定挑战的方式
        if (credential) { 
             //证书挑战 则跑到这里
           disposition = NSURLSessionAuthChallengeUseCredential; 
         }
        //完成挑战
         if (completionHandler) {
             completionHandler(disposition, credential);
         }
   }
```

其实上述就是AF的相对于自签证书的实现的简化版。  
如果是AF，你则需要设置policy：

```
//允许自签名证书，必须的
policy.allowInvalidCertificates = YES;
//是否验证域名的CN字段
//不是必须的，但是如果写YES，则必须导入证书。
policy.validatesDomainName = NO;
```

当然还可以根据需求，你可以去验证证书或者公钥，前提是，你把自签的服务端证书，或者自签的CA根证书导入到项目中：

![image.jpeg](https://p6-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/64dfccf7d08043d2ae67553e372e0b42~tplv-k3u1fbpfcp-watermark.image?)
  并且如下设置证书：
```
NSString *certFilePath = [[NSBundle mainBundle] pathForResource:@"AFUse_server.cer" ofType:nil];
NSData *certData = [NSData dataWithContentsOfFile:certFilePath];
NSSet *certSet = [NSSet setWithObjects:certData,certData, nil]; 
policy.pinnedCertificates = certSet;
```

这样你就可以使用AF的不同`AFSSLPinningMode`去验证了。

###### 最后总结一下，AF之于https到底做了什么：

-   **AF可以让你在系统验证证书之前，就去自主验证。** 然后如果自己验证不正确，直接取消网络请求。否则验证通过则继续进行系统验证。

-   讲到这，顺便提一下，系统验证的流程：

    -   系统的验证，首先是去系统的根证书找，看是否有能匹配服务端的证书，如果匹配，则验证成功，返回https的安全数据。

-   如果不匹配则去判断ATS是否关闭，如果关闭，则返回https不安全连接的数据。如果开启ATS，则拒绝这个请求，请求失败。

总之一句话：**AF的验证方式不是必须的，但是对有特殊验证需求的用户确是必要的**。

写在结尾：

-   看完之后，有些小伙伴可能还是会比较迷惑，建议还是不清楚的小伙伴，可以自己生成一个自签名的证书或者用百度地址等做请求，然后设置`AFSecurityPolicy`不同参数，打断点，一步步的看AF是如何去调用函数作证书验证的。相信这样能加深你的理解。
-   最后关于自签名证书的问题，等2017年1月1日，也没多久了...一个月不到。除非有特殊原因说明，否则已经无法审核通过了。详细的可以看看这篇文章：[iOS 10 适配 ATS（app支持https通过App Store审核）](https://www.jianshu.com/p/36ddc5b009a7)。
-

  # AFNetworking之UIKit扩展与缓存实现
  我们来看看AF对`UIkit`的扩展:
  
![image.jpeg](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/5b3adfd561d14963bac92effee999acf~tplv-k3u1fbpfcp-watermark.image?)
##### 一共如上这个多类，下面我们开始着重讲其中两个UIKit的扩展：

-   一个是我们网络请求时状态栏的小菊花。
-   一个是我们几乎都用到过请求网络图片的如下一行方法：

**

```
 - (void)setImageWithURL:(NSURL *)url ;
```

###### 我们开始吧：

###### 1.AFNetworkActivityIndicatorManager

这个类的作用相当简单，就是当网络请求的时候，状态栏上的小菊花就会开始转:

  


![]()

小菊花.png

  


需要的代码也很简单，只需在你需要它的位置中（比如AppDelegate）导入类，并加一行代码即可：

**

```
#import "AFNetworkActivityIndicatorManager.h"
```

**

```
[[AFNetworkActivityIndicatorManager sharedManager] setEnabled:YES];
```

###### 接下来我们来讲讲这个类的实现：

-   这个类的实现也非常简单，还记得我们之前讲的AF对`NSURLSessionTask`中做了一个**Method Swizzling**吗？大意是把它的`resume`和`suspend`方法做了一个替换，在原有实现的基础上添加了一个通知的发送。
-   这个类就是基于这两个通知和task完成的通知来实现的。

###### 首先我们来看看它的初始化方法：

```
+ (instancetype)sharedManager {
    static AFNetworkActivityIndicatorManager *_sharedManager = nil;
    static dispatch_once_t oncePredicate;
    dispatch_once(&oncePredicate, ^{
        _sharedManager = [[self alloc] init];
    });

    return _sharedManager;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    //设置状态为没有request活跃
    self.currentState = AFNetworkActivityManagerStateNotActive;
    //开始下载通知
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(networkRequestDidStart:) name:AFNetworkingTaskDidResumeNotification object:nil];
    //挂起通知
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(networkRequestDidFinish:) name:AFNetworkingTaskDidSuspendNotification object:nil];
    //完成通知
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(networkRequestDidFinish:) name:AFNetworkingTaskDidCompleteNotification object:nil];
    //开始延迟
    self.activationDelay = kDefaultAFNetworkActivityManagerActivationDelay;
    //结束延迟
    self.completionDelay = kDefaultAFNetworkActivityManagerCompletionDelay;
    return self;
}
```

-   初始化如上，设置了一个state，这个state是一个枚举：

```
typedef NS_ENUM(NSInteger, AFNetworkActivityManagerState) {
    //没有请求
    AFNetworkActivityManagerStateNotActive,
    //请求延迟开始
    AFNetworkActivityManagerStateDelayingStart,
    //请求进行中
    AFNetworkActivityManagerStateActive,
    //请求延迟结束
    AFNetworkActivityManagerStateDelayingEnd
};
```

这个state一共如上4种状态，其中两种应该很好理解，而延迟开始和延迟结束怎么理解呢？

-   原来这是AF对请求菊花显示做的一个优化处理，试问如果一个请求时间很短，那么菊花很可能闪一下就结束了。如果很多请求过来，那么菊花会不停的闪啊闪，这显然并不是我们想要的效果。
-   所以多了这两个参数：  
    1）在一个请求开始的时候，我延迟一会在去转菊花，如果在这延迟时间内，请求结束了，那么我就不需要去转菊花了。  
    2）但是一旦转菊花开始，哪怕很短请求就结束了，我们还是会去转一个时间再去结束，这时间就是延迟结束的时间。
-   紧接着我们监听了三个通知，用来监听当前正在进行的网络请求的状态。
-   然后设置了我们前面提到的这个转菊花延迟开始和延迟结束的时间，这两个默认值如下：

```
static NSTimeInterval const kDefaultAFNetworkActivityManagerActivationDelay = 1.0;
static NSTimeInterval const kDefaultAFNetworkActivityManagerCompletionDelay = 0.17;
```

接着我们来看看三个通知触发调用的方法：

```
//请求开始
- (void)networkRequestDidStart:(NSNotification *)notification {
    
    if ([AFNetworkRequestFromNotification(notification) URL]) {
        //增加请求活跃数
        [self incrementActivityCount];
    }
}
//请求结束
- (void)networkRequestDidFinish:(NSNotification *)notification {
    //AFNetworkRequestFromNotification(notification)返回这个通知的request,用来判断request是否是有效的
    if ([AFNetworkRequestFromNotification(notification) URL]) {
        //减少请求活跃数
        [self decrementActivityCount];
    }
}
```

方法很简单，就是开始的时候增加了请求活跃数，结束则减少。调用了如下两个方法进行加减：

```
//增加请求活跃数
- (void)incrementActivityCount {
    
    //活跃的网络数+1，并手动发送KVO
    [self willChangeValueForKey:@"activityCount"];
    @synchronized(self) {
        _activityCount++;
    }
    [self didChangeValueForKey:@"activityCount"];

    //主线程去做
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateCurrentStateForNetworkActivityChange];
    });
}

//减少请求活跃数
- (void)decrementActivityCount {
    [self willChangeValueForKey:@"activityCount"];
    @synchronized(self) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wgnu"
        _activityCount = MAX(_activityCount - 1, 0);
#pragma clang diagnostic pop
    }
    [self didChangeValueForKey:@"activityCount"];

    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateCurrentStateForNetworkActivityChange];
    });
}
```

方法做了什么应该很容易看明白，这里需要注意的是，**task的几个状态的通知，是会在多线程的环境下发送过来的**。所以这里对活跃数的加减，都用了`@synchronized`这种方式的锁，进行了线程保护。然后回到主线程调用了`updateCurrentStateForNetworkActivityChange`

我们接着来看看这个方法：

```
- (void)updateCurrentStateForNetworkActivityChange {
    //如果是允许小菊花
    if (self.enabled) {
        switch (self.currentState) {
            //不活跃
            case AFNetworkActivityManagerStateNotActive:
                //判断活跃数，大于0为YES
                if (self.isNetworkActivityOccurring) {
                    //设置状态为延迟开始
                    [self setCurrentState:AFNetworkActivityManagerStateDelayingStart];
                }
                break;
            
            case AFNetworkActivityManagerStateDelayingStart:
                //No op. Let the delay timer finish out.
                break;
            case AFNetworkActivityManagerStateActive:
                if (!self.isNetworkActivityOccurring) {
                    [self setCurrentState:AFNetworkActivityManagerStateDelayingEnd];
                }
                break;
            case AFNetworkActivityManagerStateDelayingEnd:
                if (self.isNetworkActivityOccurring) {
                    [self setCurrentState:AFNetworkActivityManagerStateActive];
                }
                break;
        }
    }
}
```

-   这个方法先是判断了我们一开始设置是否需要菊花的`self.enabled`，如果需要，才执行。
-   这里主要是根据当前的状态，来判断下一个状态应该是什么。其中有这么一个属性`self.isNetworkActivityOccurring`:

```
//判断是否活跃
 - (BOOL)isNetworkActivityOccurring {
    @synchronized(self) {
        return self.activityCount > 0;
    }
}
```

那么这个方法应该不难理解了。

这个类复写了currentState的set方法，每当我们改变这个state，就会触发set方法，而怎么该转菊花也在该方法中：

```
//设置当前小菊花状态
- (void)setCurrentState:(AFNetworkActivityManagerState)currentState {
    @synchronized(self) {
        if (_currentState != currentState) {
            //KVO
            [self willChangeValueForKey:@"currentState"];
            _currentState = currentState;
            switch (currentState) {
                //如果为不活跃
                case AFNetworkActivityManagerStateNotActive:
                    //取消两个延迟用的timer
                    [self cancelActivationDelayTimer];
                    [self cancelCompletionDelayTimer];
                    //设置小菊花不可见
                    [self setNetworkActivityIndicatorVisible:NO];
                    break;
                case AFNetworkActivityManagerStateDelayingStart:
                    //开启一个定时器延迟去转菊花
                    [self startActivationDelayTimer];
                    break;
                    //如果是活跃状态
                case AFNetworkActivityManagerStateActive:
                    //取消延迟完成的timer
                    [self cancelCompletionDelayTimer];
                    //开始转菊花
                    [self setNetworkActivityIndicatorVisible:YES];
                    break;
                    //延迟完成状态
                case AFNetworkActivityManagerStateDelayingEnd:
                    //开启延迟完成timer
                    [self startCompletionDelayTimer];
                    break;
            }
        }
        [self didChangeValueForKey:@"currentState"];
    }
}
```

这个set方法就是这个类最核心的方法了。它的作用如下：

-   这里根据当前状态，是否需要开始执行一个延迟开始或者延迟完成，又或者是否需要取消这两个延迟。
-   还判断了，是否需要去转状态栏的菊花，调用了`setNetworkActivityIndicatorVisible:`方法：

```
 - (void)setNetworkActivityIndicatorVisible:(BOOL)networkActivityIndicatorVisible {
    if (_networkActivityIndicatorVisible != networkActivityIndicatorVisible) {
        [self willChangeValueForKey:@"networkActivityIndicatorVisible"];
        @synchronized(self) {
             _networkActivityIndicatorVisible = networkActivityIndicatorVisible;
        }
        [self didChangeValueForKey:@"networkActivityIndicatorVisible"];
        
        //支持自定义的Block，去自己控制小菊花
        if (self.networkActivityActionBlock) {
            self.networkActivityActionBlock(networkActivityIndicatorVisible);
        } else {
            //否则默认AF根据该Bool，去控制状态栏小菊花是否显示
            [[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:networkActivityIndicatorVisible];
        }
    }
}
```

-   这个方法就是用来控制菊花是否转。并且支持一个自定义的Block,我们可以自己去拿到这个菊花是否应该转的状态值，去做一些自定义的处理。
-   如果我们没有实现这个Block，则调用:

```
[[UIApplication sharedApplication] setNetworkActivityIndicatorVisible:networkActivityIndicatorVisible];
```

去转菊花。

回到state的set方法中，我们除了控制菊花去转，还调用了以下4个方法：

```
//开始任务到结束的时间，默认为1秒，如果1秒就结束，那么不转菊花，延迟去开始转
- (void)startActivationDelayTimer {
    //只执行一次
    self.activationDelayTimer = [NSTimer
                                 timerWithTimeInterval:self.activationDelay target:self selector:@selector(activationDelayTimerFired) userInfo:nil repeats:NO];
    //添加到主线程runloop去触发
    [[NSRunLoop mainRunLoop] addTimer:self.activationDelayTimer forMode:NSRunLoopCommonModes];
}

//完成任务到下一个任务开始，默认为0.17秒，如果0.17秒就开始下一个，那么不停  延迟去结束菊花转
- (void)startCompletionDelayTimer {
    //先取消之前的
    [self.completionDelayTimer invalidate];
    //延迟执行让菊花不在转
    self.completionDelayTimer = [NSTimer timerWithTimeInterval:self.completionDelay target:self selector:@selector(completionDelayTimerFired) userInfo:nil repeats:NO];
    [[NSRunLoop mainRunLoop] addTimer:self.completionDelayTimer forMode:NSRunLoopCommonModes];
}

- (void)cancelActivationDelayTimer {
    [self.activationDelayTimer invalidate];
}

- (void)cancelCompletionDelayTimer {
    [self.completionDelayTimer invalidate];
}
```

这4个方法分别是开始延迟执行一个方法，和结束的时候延迟执行一个方法，和对应这两个方法的取消。其作用，注释应该很容易理解。  
我们继续往下看，这两个延迟调用的到底是什么：

```
- (void)activationDelayTimerFired {
    //活跃状态，即活跃数大于1才转
    if (self.networkActivityOccurring) {
        [self setCurrentState:AFNetworkActivityManagerStateActive];
    } else {
        [self setCurrentState:AFNetworkActivityManagerStateNotActive];
    }
}
- (void)completionDelayTimerFired {
    [self setCurrentState:AFNetworkActivityManagerStateNotActive];
}
```

一个开始，一个完成调用，都设置了不同的currentState的值，又回到之前`state`的`set`方法中了。

至此这个`AFNetworkActivityIndicatorManager`类就讲完了，代码还是相当简单明了的。

### 2.UIImageView+AFNetworking

接下来我们来讲一个我们经常用的方法，这个方法的实现类是：`UIImageView+AFNetworking.h`。  
这是个类目，并且给UIImageView扩展了4个方法：

```
- (void)setImageWithURL:(NSURL *)url;
- (void)setImageWithURL:(NSURL *)url
placeholderImage:(nullable UIImage *)placeholderImage;

- (void)setImageWithURLRequest:(NSURLRequest *)urlRequest
      placeholderImage:(nullable UIImage *)placeholderImage
               success:(nullable void (^)(NSURLRequest *request, NSHTTPURLResponse * _Nullable response, UIImage *image))success
               failure:(nullable void (^)(NSURLRequest *request, NSHTTPURLResponse * _Nullable response, NSError *error))failure;
- (void)cancelImageDownloadTask;
```

-   前两个想必不用我说了，没有谁没用过吧...就是给一个UIImageView去异步的请求一张图片，并且可以设置一张占位图。
-   第3个方法设置一张图，并且可以拿到成功和失败的回调。
-   第4个方法，可以取消当前的图片设置请求。

无论`SDWebImage`,还是`YYKit`,或者`AF`，都实现了这么个类目。  
AF关于这个类目`UIImageView+AFNetworking`的实现，**依赖于这么两个类：`AFImageDownloader`，`AFAutoPurgingImageCache`。**  
当然`AFImageDownloader`中，关于图片数据请求的部分，还是使用`AFURLSessionManager`来实现的。

#### 接下来我们就来看看AFImageDownloader：

先看看初始化方法：

```
//该类为单例
+ (instancetype)defaultInstance {
    static AFImageDownloader *sharedInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedInstance = [[self alloc] init];
    });
    return sharedInstance;
}
- (instancetype)init {
    NSURLSessionConfiguration *defaultConfiguration = [self.class defaultURLSessionConfiguration];
    AFHTTPSessionManager *sessionManager = [[AFHTTPSessionManager alloc] initWithSessionConfiguration:defaultConfiguration];
    sessionManager.responseSerializer = [AFImageResponseSerializer serializer];

    return [self initWithSessionManager:sessionManager
                 downloadPrioritization:AFImageDownloadPrioritizationFIFO
                 maximumActiveDownloads:4
                             imageCache:[[AFAutoPurgingImageCache alloc] init]];
}
+ (NSURLSessionConfiguration *)defaultURLSessionConfiguration {
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];

    //TODO set the default HTTP headers

    configuration.HTTPShouldSetCookies = YES;
    configuration.HTTPShouldUsePipelining = NO;

    configuration.requestCachePolicy = NSURLRequestUseProtocolCachePolicy;
    //是否允许蜂窝网络，手机网
    configuration.allowsCellularAccess = YES;
    //默认超时
    configuration.timeoutIntervalForRequest = 60.0;
    //设置的图片缓存对象
    configuration.URLCache = [AFImageDownloader defaultURLCache];

    return configuration;
}
```

该类为单例，上述方法中，创建了一个`sessionManager`,这个`sessionManager`将用于我们之后的网络请求。从这里我们可以看到，这个类的网络请求都是基于之前AF自己封装的`AFHTTPSessionManager`。

-   在这里初始化了一系列的对象，需要讲一下的是`AFImageDownloadPrioritizationFIFO`，这个一个枚举值：

```
typedef NS_ENUM(NSInteger, AFImageDownloadPrioritization) {
    //先进先出
    AFImageDownloadPrioritizationFIFO,
    //后进先出
    AFImageDownloadPrioritizationLIFO
};
```

这个枚举值代表着，一堆图片下载，执行任务的顺序。

-   还有一个`AFAutoPurgingImageCache`的创建，这个类是AF做图片缓存用的。这里我们暂时就这么理解它，讲完当前类，我们再来补充它。
-   除此之外，我们还看到一个cache:
```
configuration.URLCache = [AFImageDownloader defaultURLCache];
```

```
//设置一个系统缓存，内存缓存为20M，磁盘缓存为150M，
//这个是系统级别维护的缓存。
 + (NSURLCache *)defaultURLCache {
    return [[NSURLCache alloc] initWithMemoryCapacity:20 * 1024 * 1024
                                         diskCapacity:150 * 1024 * 1024
                                             diskPath:@"com.alamofire.imagedownloader"];
}
```

大家看到这可能迷惑了，怎么这么多cache，那AF做图片缓存到底用哪个呢？答案是AF自己控制的图片缓存用`AFAutoPurgingImageCache`，而`NSUrlRequest`的缓存由它自己内部根据策略去控制，用的是`NSURLCache`，不归AF处理，只需在configuration中设置上即可。

-   那么看到这有些小伙伴又要问了，为什么不直接用`NSURLCache`，还要自定义一个`AFAutoPurgingImageCache`呢？原来是因为`NSURLCache`的诸多限制，例如只支持get请求等等。而且因为是系统维护的，我们自己的可控度不强，并且如果需要做一些自定义的缓存处理，无法实现。
-   更多关于`NSURLCache`的内容，大家可以自行查阅。

接着上面的方法调用到这个最终的初始化方法中：

```
- (instancetype)initWithSessionManager:(AFHTTPSessionManager *)sessionManager
                downloadPrioritization:(AFImageDownloadPrioritization)downloadPrioritization
                maximumActiveDownloads:(NSInteger)maximumActiveDownloads
                            imageCache:(id <AFImageRequestCache>)imageCache {
    if (self = [super init]) {
        //持有
        self.sessionManager = sessionManager;
        //定义下载任务的顺序，默认FIFO，先进先出-队列模式，还有后进先出-栈模式
        self.downloadPrioritizaton = downloadPrioritization;
        //最大的下载数
        self.maximumActiveDownloads = maximumActiveDownloads;
        
        //自定义的cache
        self.imageCache = imageCache;

        //队列中的任务，待执行的
        self.queuedMergedTasks = [[NSMutableArray alloc] init];
        //合并的任务，所有任务的字典
        self.mergedTasks = [[NSMutableDictionary alloc] init];
        //活跃的request数
        self.activeRequestCount = 0;

        //用UUID来拼接名字
        NSString *name = [NSString stringWithFormat:@"com.alamofire.imagedownloader.synchronizationqueue-%@", [[NSUUID UUID] UUIDString]];
        //创建一个串行的queue
        self.synchronizationQueue = dispatch_queue_create([name cStringUsingEncoding:NSASCIIStringEncoding], DISPATCH_QUEUE_SERIAL);

        name = [NSString stringWithFormat:@"com.alamofire.imagedownloader.responsequeue-%@", [[NSUUID UUID] UUIDString]];
        //创建并行queue
        self.responseQueue = dispatch_queue_create([name cStringUsingEncoding:NSASCIIStringEncoding], DISPATCH_QUEUE_CONCURRENT);
    }

    return self;
}
```

这边初始化了一些属性，这些属性跟着注释看应该很容易明白其作用。主要需要注意的就是，这里创建了两个queue：**一个串行的请求queue，和一个并行的响应queue。**

-   这个串行queue,是用来做内部生成task等等一系列业务逻辑的。它保证了我们在这些逻辑处理中的线程安全问题（迷惑的接着往下看）。
-   这个并行queue，被用来做网络请求完成的数据回调。

接下来我们来看看它的创建请求task的方法：

```
- (nullable AFImageDownloadReceipt *)downloadImageForURLRequest:(NSURLRequest *)request
                                                        success:(void (^)(NSURLRequest * _Nonnull, NSHTTPURLResponse * _Nullable, UIImage * _Nonnull))success
                                                        failure:(void (^)(NSURLRequest * _Nonnull, NSHTTPURLResponse * _Nullable, NSError * _Nonnull))failure {
    return [self downloadImageForURLRequest:request withReceiptID:[NSUUID UUID] success:success failure:failure];
}

- (nullable AFImageDownloadReceipt *)downloadImageForURLRequest:(NSURLRequest *)request
                                                  withReceiptID:(nonnull NSUUID *)receiptID
                                                        success:(nullable void (^)(NSURLRequest *request, NSHTTPURLResponse  * _Nullable response, UIImage *responseObject))success
                                                        failure:(nullable void (^)(NSURLRequest *request, NSHTTPURLResponse * _Nullable response, NSError *error))failure {
    //还是类似之前的，同步串行去做下载的事 生成一个task,这些事情都是在当前线程中串行同步做的，所以不用担心线程安全问题。
    __block NSURLSessionDataTask *task = nil;
    dispatch_sync(self.synchronizationQueue, ^{
        //url字符串
        NSString *URLIdentifier = request.URL.absoluteString;
        if (URLIdentifier == nil) {
            if (failure) {
                //错误返回，没Url
                NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadURL userInfo:nil];
                dispatch_async(dispatch_get_main_queue(), ^{
                    failure(request, nil, error);
                });
            }
            return;
        }

        //如果这个任务已经存在，则添加成功失败Block,然后直接返回，即一个url用一个request,可以响应好几个block
        //从自己task字典中根据Url去取AFImageDownloaderMergedTask，里面有task id url等等信息
        AFImageDownloaderMergedTask *existingMergedTask = self.mergedTasks[URLIdentifier];
        if (existingMergedTask != nil) {
            //里面包含成功和失败Block和UUid
            AFImageDownloaderResponseHandler *handler = [[AFImageDownloaderResponseHandler alloc] initWithUUID:receiptID success:success failure:failure];
            //添加handler
            [existingMergedTask addResponseHandler:handler];
            //给task赋值
            task = existingMergedTask.task;
            return;
        }

        //根据request的缓存策略，加载缓存
        switch (request.cachePolicy) {
            //这3种情况都会去加载缓存
            case NSURLRequestUseProtocolCachePolicy:
            case NSURLRequestReturnCacheDataElseLoad:
            case NSURLRequestReturnCacheDataDontLoad: {
                //从cache中根据request拿数据
                UIImage *cachedImage = [self.imageCache imageforRequest:request withAdditionalIdentifier:nil];
                if (cachedImage != nil) {
                    if (success) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            success(request, nil, cachedImage);
                        });
                    }
                    return;
                }
                break;
            }
            default:
                break;
        }

        //走到这说明即没有请求中的request,也没有cache,开始请求
        NSUUID *mergedTaskIdentifier = [NSUUID UUID];
        //task
        NSURLSessionDataTask *createdTask;
        __weak __typeof__(self) weakSelf = self;
        
        //用sessionManager的去请求，注意，只是创建task,还是挂起状态
        createdTask = [self.sessionManager
                       dataTaskWithRequest:request
                       completionHandler:^(NSURLResponse * _Nonnull response, id  _Nullable responseObject, NSError * _Nullable error) {
                           
                           //在responseQueue中回调数据,初始化为并行queue
                           dispatch_async(self.responseQueue, ^{
                               __strong __typeof__(weakSelf) strongSelf = weakSelf;
                               
                               //拿到当前的task
                               AFImageDownloaderMergedTask *mergedTask = self.mergedTasks[URLIdentifier];
                               
                               //如果之前的task数组中，有这个请求的任务task，则从数组中移除
                               if ([mergedTask.identifier isEqual:mergedTaskIdentifier]) {
                                   //安全的移除，并返回当前被移除的AF task
                                   mergedTask = [strongSelf safelyRemoveMergedTaskWithURLIdentifier:URLIdentifier];
                                   //请求错误
                                   if (error) {
                                       //去遍历task所有响应的处理
                                       for (AFImageDownloaderResponseHandler *handler in mergedTask.responseHandlers) {
                                           //主线程，调用失败的Block
                                           if (handler.failureBlock) {
                                               dispatch_async(dispatch_get_main_queue(), ^{
                                                   handler.failureBlock(request, (NSHTTPURLResponse*)response, error);
                                               });
                                           }
                                       }
                                   } else {
                                       //成功根据request,往cache里添加
                                       [strongSelf.imageCache addImage:responseObject forRequest:request withAdditionalIdentifier:nil];
                                       //调用成功Block
                                       for (AFImageDownloaderResponseHandler *handler in mergedTask.responseHandlers) {
                                           if (handler.successBlock) {
                                               dispatch_async(dispatch_get_main_queue(), ^{
                                                   handler.successBlock(request, (NSHTTPURLResponse*)response, responseObject);
                                               });
                                           }
                                       }
                                       
                                   }
                               }
                               //减少活跃的任务数
                               [strongSelf safelyDecrementActiveTaskCount];
                               [strongSelf safelyStartNextTaskIfNecessary];
                           });
                       }];

        // 4) Store the response handler for use when the request completes
        //创建handler
        AFImageDownloaderResponseHandler *handler = [[AFImageDownloaderResponseHandler alloc] initWithUUID:receiptID
                                                                                                   success:success
                                                                                                   failure:failure];
        //创建task
        AFImageDownloaderMergedTask *mergedTask = [[AFImageDownloaderMergedTask alloc]
                                                   initWithURLIdentifier:URLIdentifier
                                                   identifier:mergedTaskIdentifier
                                                   task:createdTask];
        //添加handler
        [mergedTask addResponseHandler:handler];
        //往当前任务字典里添加任务
        self.mergedTasks[URLIdentifier] = mergedTask;

        // 5) Either start the request or enqueue it depending on the current active request count
        //如果小于，则开始任务下载resume
        if ([self isActiveRequestCountBelowMaximumLimit]) {
            [self startMergedTask:mergedTask];
        } else {
            
            [self enqueueMergedTask:mergedTask];
        }
        //拿到最终生成的task
        task = mergedTask.task;
    });
    if (task) {
        //创建一个AFImageDownloadReceipt并返回，里面就多一个receiptID。
        return [[AFImageDownloadReceipt alloc] initWithReceiptID:receiptID task:task];
    } else {
        return nil;
    }
}
```

就这么一个非常非常长的方法，这个方法执行的内容都是在我们之前创建的串行queue中，同步的执行的，这是因为这个方法绝大多数的操作都是需要线程安全的。可以对着源码和注释来看，我们在这讲下它做了什么：

1.  首先做了一个url的判断，如果为空则返回失败Block。
1.  判断这个需要请求的url，是不是已经被生成的task中，如果是的话，则多添加一个回调处理就可以。回调处理对象为`AFImageDownloaderResponseHandler`。这个类非常简单，总共就如下3个属性：

```
@interface AFImageDownloaderResponseHandler : NSObject
@property (nonatomic, strong) NSUUID *uuid;
@property (nonatomic, copy) void (^successBlock)(NSURLRequest*, NSHTTPURLResponse*, UIImage*);
@property (nonatomic, copy) void (^failureBlock)(NSURLRequest*, NSHTTPURLResponse*, NSError*);
@end
@implementation AFImageDownloaderResponseHandler
//初始化回调对象
 - (instancetype)initWithUUID:(NSUUID *)uuid
                     success:(nullable void (^)(NSURLRequest *request, NSHTTPURLResponse * _Nullable response, UIImage *responseObject))success
                     failure:(nullable void (^)(NSURLRequest *request, NSHTTPURLResponse * _Nullable response, NSError *error))failure {
    if (self = [self init]) {
        self.uuid = uuid;
        self.successBlock = success;
        self.failureBlock = failure;
    }
    return self;
}
```

当这个task完成的时候，会调用我们添加的回调。

3.  关于`AFImageDownloaderMergedTask`，我们在这里都用的是这种类型的task，其实这个task也很简单：

```
@interface AFImageDownloaderMergedTask : NSObject
@property (nonatomic, strong) NSString *URLIdentifier;
@property (nonatomic, strong) NSUUID *identifier;
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSMutableArray <AFImageDownloaderResponseHandler*> *responseHandlers;
@end
@implementation AFImageDownloaderMergedTask
 - (instancetype)initWithURLIdentifier:(NSString *)URLIdentifier identifier:(NSUUID *)identifier task:(NSURLSessionDataTask *)task {
    if (self = [self init]) {
        self.URLIdentifier = URLIdentifier;
        self.task = task;
        self.identifier = identifier;
        self.responseHandlers = [[NSMutableArray alloc] init];
    }
    return self;
}
//添加任务完成回调
 - (void)addResponseHandler:(AFImageDownloaderResponseHandler*)handler {
    [self.responseHandlers addObject:handler];
}
//移除任务完成回调
 - (void)removeResponseHandler:(AFImageDownloaderResponseHandler*)handler {
    [self.responseHandlers removeObject:handler];
}
@end
```

其实就是除了`NSURLSessionDataTask`，多加了几个参数，`URLIdentifier`和`identifier`都是用来标识这个task的，responseHandlers是用来存储task完成后的回调的，里面可以存一组，当任务完成时候，里面的回调都会被调用。

4.  接着去根据缓存策略，去加载缓存，如果有缓存，从`self.imageCache`中返回缓存，否则继续往下走。
4.  走到这说明没相同url的task，也没有cache，那么就开始一个新的task，调用的是`AFUrlSessionManager`里的请求方法生成了一个task（这里我们就不赘述了，可以看之前的楼主之前的文章）。然后做了请求完成的处理。注意，这里处理实在我们一开始初始化的并行queue:`self.responseQueue`中的，这里的响应处理是多线程并发进行的。  
    1）完成，则调用如下方法把这个task从全局字典中移除：

```
 //移除task相关，用同步串行的形式，防止移除中出现重复移除一系列问题
  - (AFImageDownloaderMergedTask*)safelyRemoveMergedTaskWithURLIdentifier:(NSString *)URLIdentifier {
    __block AFImageDownloaderMergedTask *mergedTask = nil;
    dispatch_sync(self.synchronizationQueue, ^{
        mergedTask = [self removeMergedTaskWithURLIdentifier:URLIdentifier];
    });
    return mergedTask;
}
```

2）去循环这个task的`responseHandlers`，调用它的成功或者失败的回调。  
3）并且调用下面两个方法，去减少正在请求的任务数，和开启下一个任务：

**

```
//减少活跃的任务数
 - (void)safelyDecrementActiveTaskCount {
    //回到串行queue去-
    dispatch_sync(self.synchronizationQueue, ^{
        if (self.activeRequestCount > 0) {
            self.activeRequestCount -= 1;
        }
    });
}
//如果可以，则开启下一个任务
 - (void)safelyStartNextTaskIfNecessary {
    //回到串行queue
    dispatch_sync(self.synchronizationQueue, ^{
        //先判断并行数限制
        if ([self isActiveRequestCountBelowMaximumLimit]) {
            while (self.queuedMergedTasks.count > 0) {
                //获取数组中第一个task
                AFImageDownloaderMergedTask *mergedTask = [self dequeueMergedTask];
                //如果状态是挂起状态
                if (mergedTask.task.state == NSURLSessionTaskStateSuspended) {
                    [self startMergedTask:mergedTask];
                    break;
                }
            }
        }
    });
}
```

这里需要注意的是，跟我们本类的一些数据相关的操作，**都是在我们一开始的串行queue中同步进行的。**  
4）除此之外，如果成功，还把成功请求到的数据，加到AF自定义的cache中：

**

```
//成功根据request,往cache里添加
[strongSelf.imageCache addImage:responseObject forRequest:request withAdditionalIdentifier:nil];
```

6.  用`NSUUID`生成的唯一标识，去生成`AFImageDownloaderResponseHandler`，然后生成一个`AFImageDownloaderMergedTask`，把之前第5步生成的`createdTask`和回调都绑定给这个AF自定义可合并回调的task，然后这个task加到全局的task映射字典中，key为url:

```
self.mergedTasks[URLIdentifier] = mergedTask;
```

7.  判断当前正在下载的任务是否超过最大并行数，如果没有则开始下载，否则先加到等待的数组中去:

```
//如果小于最大并行数，则开始任务下载resume
if ([self isActiveRequestCountBelowMaximumLimit]) {
    [self startMergedTask:mergedTask];
} else {
    
    [self enqueueMergedTask:mergedTask];
}
```

```
//判断并行数限制
 - (BOOL)isActiveRequestCountBelowMaximumLimit {
    return self.activeRequestCount < self.maximumActiveDownloads;
}
```

```
//开始下载
 - (void)startMergedTask:(AFImageDownloaderMergedTask *)mergedTask {
    [mergedTask.task resume];
    //任务活跃数+1
    ++self.activeRequestCount;
}
//把任务先加到数组里
 - (void)enqueueMergedTask:(AFImageDownloaderMergedTask *)mergedTask {
    switch (self.downloadPrioritizaton) {
            //先进先出
        case AFImageDownloadPrioritizationFIFO:
            [self.queuedMergedTasks addObject:mergedTask];
            break;
            //后进先出
        case AFImageDownloadPrioritizationLIFO:
            [self.queuedMergedTasks insertObject:mergedTask atIndex:0];
            break;
    }
}
```

-   先判断并行数限制，如果小于最大限制，则开始下载，把当前活跃的request数量+1。
-   如果暂时不能下载，被加到等待下载的数组中去的话，会根据我们一开始设置的下载策略，是先进先出，还是后进先出，去插入这个下载任务。

8.  最后判断这个mergeTask是否为空。不为空，我们生成了一个`AFImageDownloadReceipt`，绑定了一个UUID。否则为空返回nil：

**

```
if (task) {
    //创建一个AFImageDownloadReceipt并返回，里面就多一个receiptID。
    return [[AFImageDownloadReceipt alloc] initWithReceiptID:receiptID task:task];
} else {
    return nil;
}
```

这个`AFImageDownloadReceipt`仅仅是多封装了一个UUID:

```
@interface AFImageDownloadReceipt : NSObject
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSUUID *receiptID;
@end
@implementation AFImageDownloadReceipt
 - (instancetype)initWithReceiptID:(NSUUID *)receiptID task:(NSURLSessionDataTask *)task {
    if (self = [self init]) {
        self.receiptID = receiptID;
        self.task = task;
    }
    return self;
}
```

这么封装是为了标识每一个task，我们后面可以根据这个`AFImageDownloadReceipt`来对task做取消操作。

这个`AFImageDownloader`中最核心的方法基本就讲完了，还剩下一些方法没讲，像前面讲到的task的取消的方法：

**

```
//根据AFImageDownloadReceipt来取消任务，即对应一个响应回调。
- (void)cancelTaskForImageDownloadReceipt:(AFImageDownloadReceipt *)imageDownloadReceipt {
    dispatch_sync(self.synchronizationQueue, ^{
        //拿到url
        NSString *URLIdentifier = imageDownloadReceipt.task.originalRequest.URL.absoluteString;
        //根据url拿到task
        AFImageDownloaderMergedTask *mergedTask = self.mergedTasks[URLIdentifier];
        
        //快速遍历查找某个下标，如果返回YES，则index为当前下标
        NSUInteger index = [mergedTask.responseHandlers indexOfObjectPassingTest:^BOOL(AFImageDownloaderResponseHandler * _Nonnull handler, __unused NSUInteger idx, __unused BOOL * _Nonnull stop) {
            
            return handler.uuid == imageDownloadReceipt.receiptID;
        }];

        if (index != NSNotFound) {
            //移除响应处理
            AFImageDownloaderResponseHandler *handler = mergedTask.responseHandlers[index];
            [mergedTask removeResponseHandler:handler];
            NSString *failureReason = [NSString stringWithFormat:@"ImageDownloader cancelled URL request: %@",imageDownloadReceipt.task.originalRequest.URL.absoluteString];
            NSDictionary *userInfo = @{NSLocalizedFailureReasonErrorKey:failureReason};
            NSError *error = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:userInfo];
            //并调用失败block，原因为取消
            if (handler.failureBlock) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    handler.failureBlock(imageDownloadReceipt.task.originalRequest, nil, error);
                });
            }
        }
        
        //如果任务里的响应回调为空或者状态为挂起，则取消task,并且从字典中移除
        if (mergedTask.responseHandlers.count == 0 && mergedTask.task.state == NSURLSessionTaskStateSuspended) {
            [mergedTask.task cancel];
            [self removeMergedTaskWithURLIdentifier:URLIdentifier];
        }
    });
}
```

```
//根据URLIdentifier移除task
- (AFImageDownloaderMergedTask *)removeMergedTaskWithURLIdentifier:(NSString *)URLIdentifier {
    AFImageDownloaderMergedTask *mergedTask = self.mergedTasks[URLIdentifier];
    [self.mergedTasks removeObjectForKey:URLIdentifier];
    return mergedTask;
}
```

方法比较简单，大家自己看看就好。至此```AFImageDownloader``这个类讲完了。如果大家看的感觉比较绕，没关系，等到最后我们一起来总结一下，捋一捋。


### AFAutoPurgingImageCache
我们之前讲到`AFAutoPurgingImageCache`这个类略过去了，现在我们就来补充一下这个类的相关内容：  
首先来讲讲这个类的作用，它是AF自定义用来做图片缓存的。我们来看看它的初始化方法：

**

```
- (instancetype)init {
    //默认为内存100M，后者为缓存溢出后保留的内存
    return [self initWithMemoryCapacity:100 * 1024 * 1024 preferredMemoryCapacity:60 * 1024 * 1024];
}

- (instancetype)initWithMemoryCapacity:(UInt64)memoryCapacity preferredMemoryCapacity:(UInt64)preferredMemoryCapacity {
    if (self = [super init]) {
        //内存大小
        self.memoryCapacity = memoryCapacity;
        self.preferredMemoryUsageAfterPurge = preferredMemoryCapacity;
        //cache的字典
        self.cachedImages = [[NSMutableDictionary alloc] init];

        NSString *queueName = [NSString stringWithFormat:@"com.alamofire.autopurgingimagecache-%@", [[NSUUID UUID] UUIDString]];
        //并行的queue
        self.synchronizationQueue = dispatch_queue_create([queueName cStringUsingEncoding:NSASCIIStringEncoding], DISPATCH_QUEUE_CONCURRENT);

        //添加通知，收到内存警告的通知
        [[NSNotificationCenter defaultCenter]
         addObserver:self
         selector:@selector(removeAllImages)
         name:UIApplicationDidReceiveMemoryWarningNotification
         object:nil];

    }
    return self;
}
```

初始化方法很简单，总结一下：

1.  声明了一个默认的内存缓存大小100M，还有一个意思是如果超出100M之后，我们去清除缓存，此时仍要保留的缓存大小60M。（如果还是不理解，可以看后文，源码中会讲到）
1.  创建了一个并行queue，这个并行queue，**这个类除了初始化以外，所有的方法都是在这个并行queue中调用的。**
1.  创建了一个cache字典，我们所有的缓存数据，都被保存在这个字典中，key为url，value为`AFCachedImage`。  
    关于这个`AFCachedImage`，其实就是Image之外封装了几个关于这个缓存的参数，如下：

**

```
@interface AFCachedImage : NSObject
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, strong) NSString *identifier;  //url标识
@property (nonatomic, assign) UInt64 totalBytes;   //总大小
@property (nonatomic, strong) NSDate *lastAccessDate;  //上次获取时间
@property (nonatomic, assign) UInt64 currentMemoryUsage; //这个参数没被用到过
@end
@implementation AFCachedImage
//初始化
 -(instancetype)initWithImage:(UIImage *)image identifier:(NSString *)identifier {
    if (self = [self init]) {
        self.image = image;
        self.identifier = identifier;

        CGSize imageSize = CGSizeMake(image.size.width * image.scale, image.size.height * image.scale);
        CGFloat bytesPerPixel = 4.0;
        CGFloat bytesPerSize = imageSize.width * imageSize.height;
        self.totalBytes = (UInt64)bytesPerPixel * (UInt64)bytesPerSize;
        self.lastAccessDate = [NSDate date];
    }
    return self;
}
//上次获取缓存的时间
 - (UIImage*)accessImage {
    self.lastAccessDate = [NSDate date];
    return self.image;
}
```

4.  添加了一个通知，监听内存警告，当发成内存警告，调用该方法，移除所有的缓存，并且把当前缓存数置为0：

**

```
//移除所有图片
 - (BOOL)removeAllImages {
    __block BOOL removed = NO;
    dispatch_barrier_sync(self.synchronizationQueue, ^{
        if (self.cachedImages.count > 0) {
            [self.cachedImages removeAllObjects];
            self.currentMemoryUsage = 0;
            removed = YES;
        }
    });
    return removed;
}
```

注意这个类大量的使用了`dispatch_barrier_sync`与`dispatch_barrier_async`，小伙伴们如果对这两个方法有任何疑惑，可以看看这篇文章：[dispatch_barrier_async与dispatch_barrier_sync异同](http://blog.csdn.net/u013046795/article/details/47057585)。  
1）这里我们可以看到使用了`dispatch_barrier_sync`，这里没有用锁，但是因为使用了`dispatch_barrier_sync`，不仅同步了`synchronizationQueue`队列，而且阻塞了当前线程，所以保证了里面执行代码的线程安全问题。  
2）在这里其实使用锁也可以，但是AF在这的处理却是使用同步的机制来保证线程安全，**或许这跟图片的加载缓存的使用场景，高频次有关系**，在这里使用sync，并不需要在去开辟新的线程，浪费性能，只需要在原有线程，提交到`synchronizationQueue`队列中，阻塞的执行即可。这样省去大量的开辟线程与使用锁带来的性能消耗。（当然这仅仅是我的一个猜测，有不同意见的朋友欢迎讨论~）

-   在这里用了`dispatch_barrier_sync`，因为`synchronizationQueue`是个并行queue，所以在这里不会出现死锁的问题。
-   关于保证线程安全的同时，同步还是异步，与性能方面的考量，可以参考这篇文章：[Objc的底层并发API](http://www.cocoachina.com/industry/20130821/6842.html)。

接着我们来看看这个类最核心的一个方法：

**

```
//添加image到cache里
- (void)addImage:(UIImage *)image withIdentifier:(NSString *)identifier {
   
    //用dispatch_barrier_async，来同步这个并行队列
    dispatch_barrier_async(self.synchronizationQueue, ^{
        //生成cache对象
        AFCachedImage *cacheImage = [[AFCachedImage alloc] initWithImage:image identifier:identifier];
        
        //去之前cache的字典里取
        AFCachedImage *previousCachedImage = self.cachedImages[identifier];
        //如果有被缓存过
        if (previousCachedImage != nil) {
            //当前已经使用的内存大小减去图片的大小
            self.currentMemoryUsage -= previousCachedImage.totalBytes;
        }
        //把新cache的image加上去
        self.cachedImages[identifier] = cacheImage;
        //加上内存大小
        self.currentMemoryUsage += cacheImage.totalBytes;
    });

    //做缓存溢出的清除，清除的是早期的缓存
    dispatch_barrier_async(self.synchronizationQueue, ^{
        //如果使用的内存大于我们设置的内存容量
        if (self.currentMemoryUsage > self.memoryCapacity) {
            //拿到使用内存 - 被清空后首选内存 =  需要被清除的内存
            UInt64 bytesToPurge = self.currentMemoryUsage - self.preferredMemoryUsageAfterPurge;
            //拿到所有缓存的数据
            NSMutableArray <AFCachedImage*> *sortedImages = [NSMutableArray arrayWithArray:self.cachedImages.allValues];
            
            //根据lastAccessDate排序 升序，越晚的越后面
            NSSortDescriptor *sortDescriptor = [[NSSortDescriptor alloc] initWithKey:@"lastAccessDate"
                                                                           ascending:YES];
            
            [sortedImages sortUsingDescriptors:@[sortDescriptor]];

            UInt64 bytesPurged = 0;
            //移除早期的cache bytesToPurge大小
            for (AFCachedImage *cachedImage in sortedImages) {
                [self.cachedImages removeObjectForKey:cachedImage.identifier];
                bytesPurged += cachedImage.totalBytes;
                if (bytesPurged >= bytesToPurge) {
                    break ;
                }
            }
            //减去被清掉的内存
            self.currentMemoryUsage -= bytesPurged;
        }
    });
}
```

看注释应该很容易明白，这个方法做了两件事：

1.  设置缓存到字典里，并且把对应的缓存大小设置到当前已缓存的数量属性中。
1.  判断是缓存超出了我们设置的最大缓存100M，如果是的话，则清除掉部分早时间的缓存，清除到缓存小于我们溢出后保留的内存60M以内。

当然在这里更需要说一说的是`dispatch_barrier_async`，这里整个类都没有使用`dispatch_async`，所以不存在是为了做一个栅栏，来同步上下文的线程。其实它在本类中的作用很简单，就是一个串行执行。

-   讲到这，小伙伴们又疑惑了，既然就是只是为了串行，那为什么我们不用一个串行queue就得了？非得用`dispatch_barrier_async`干嘛？其实小伙伴要是看的仔细，就明白了，上文我们说过，我们要用`dispatch_barrier_sync`来保证线程安全。**如果我们使用串行queue,那么线程是极其容易死锁的。**

还有剩下的几个方法：

**

```
//根据id获取图片
- (nullable UIImage *)imageWithIdentifier:(NSString *)identifier {
    __block UIImage *image = nil;
    //用同步的方式获取，防止线程安全问题
    dispatch_sync(self.synchronizationQueue, ^{
        AFCachedImage *cachedImage = self.cachedImages[identifier];
        //并且刷新获取的时间
        image = [cachedImage accessImage];
    });
    return image;
}

//根据request和additionalIdentifier添加cache
- (void)addImage:(UIImage *)image forRequest:(NSURLRequest *)request withAdditionalIdentifier:(NSString *)identifier {
    [self addImage:image withIdentifier:[self imageCacheKeyFromURLRequest:request withAdditionalIdentifier:identifier]];
}

//根据request和additionalIdentifier移除图片
- (BOOL)removeImageforRequest:(NSURLRequest *)request withAdditionalIdentifier:(NSString *)identifier {
    return [self removeImageWithIdentifier:[self imageCacheKeyFromURLRequest:request withAdditionalIdentifier:identifier]];
}
//根据request和additionalIdentifier获取图片

- (nullable UIImage *)imageforRequest:(NSURLRequest *)request withAdditionalIdentifier:(NSString *)identifier {
    return [self imageWithIdentifier:[self imageCacheKeyFromURLRequest:request withAdditionalIdentifier:identifier]];
}

//生成id的方式为Url字符串+additionalIdentifier
- (NSString *)imageCacheKeyFromURLRequest:(NSURLRequest *)request withAdditionalIdentifier:(NSString *)additionalIdentifier {
    NSString *key = request.URL.absoluteString;
    if (additionalIdentifier != nil) {
        key = [key stringByAppendingString:additionalIdentifier];
    }
    return key;
}
```

这几个方法都很简单，大家自己看看就好了，就不赘述了。至此`AFAutoPurgingImageCache`也讲完了，我们还是等到最后再来总结。

  
###  回到`UIImageView+AFNetworking`
  我们绕了一大圈，总算回到了`UIImageView+AFNetworking`这个类，现在图片下载的方法，和缓存的方法都有了，实现这个类也是水到渠成的事了。

我们来看下面我们绝大多数人很熟悉的方法，看看它的实现：

**

```
- (void)setImageWithURL:(NSURL *)url {
    [self setImageWithURL:url placeholderImage:nil];
}

- (void)setImageWithURL:(NSURL *)url
       placeholderImage:(UIImage *)placeholderImage
{
    //设置head，可接受类型为image
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    [request addValue:@"image/*" forHTTPHeaderField:@"Accept"];

    [self setImageWithURLRequest:request placeholderImage:placeholderImage success:nil failure:nil];
}
```

上述方法按顺序往下调用，第二个方法给head的Accept类型设置为Image。接着调用到第三个方法，也是这个类目唯一一个重要的方法：

**

```
- (void)setImageWithURLRequest:(NSURLRequest *)urlRequest
              placeholderImage:(UIImage *)placeholderImage
                       success:(void (^)(NSURLRequest *request, NSHTTPURLResponse * _Nullable response, UIImage *image))success
                       failure:(void (^)(NSURLRequest *request, NSHTTPURLResponse * _Nullable response, NSError *error))failure
{
    //url为空，则取消
    if ([urlRequest URL] == nil) {
        //取消task
        [self cancelImageDownloadTask];
        //设置为占位图
        self.image = placeholderImage;
        return;
    }
    
    //看看设置的当前的回调的request和需要请求的request是不是为同一个，是的话为重复调用，直接返回
    if ([self isActiveTaskURLEqualToURLRequest:urlRequest]){
        return;
    }
    
    //开始请求前，先取消之前的task,即解绑回调
    [self cancelImageDownloadTask];

    //拿到downloader
    AFImageDownloader *downloader = [[self class] sharedImageDownloader];
    //拿到cache
    id <AFImageRequestCache> imageCache = downloader.imageCache;

    //Use the image from the image cache if it exists
    UIImage *cachedImage = [imageCache imageforRequest:urlRequest withAdditionalIdentifier:nil];
    //去获取cachedImage
    if (cachedImage) {
        //有的话直接设置，并且置空回调
        if (success) {
            success(urlRequest, nil, cachedImage);
        } else {
            self.image = cachedImage;
        }
        [self clearActiveDownloadInformation];
    } else {
        //无缓存，如果有占位图，先设置
        if (placeholderImage) {
            self.image = placeholderImage;
        }

        __weak __typeof(self)weakSelf = self;
        NSUUID *downloadID = [NSUUID UUID];
        AFImageDownloadReceipt *receipt;
        //去下载，并得到一个receipt，可以用来取消回调
        receipt = [downloader
                   downloadImageForURLRequest:urlRequest
                   withReceiptID:downloadID
                   success:^(NSURLRequest * _Nonnull request, NSHTTPURLResponse * _Nullable response, UIImage * _Nonnull responseObject) {
                       __strong __typeof(weakSelf)strongSelf = weakSelf;
                       //判断receiptID和downloadID是否相同 成功回调，设置图片
                       if ([strongSelf.af_activeImageDownloadReceipt.receiptID isEqual:downloadID]) {
                           if (success) {
                               success(request, response, responseObject);
                           } else if(responseObject) {
                               strongSelf.image = responseObject;
                           }
                           //置空回调
                           [strongSelf clearActiveDownloadInformation];
                       }

                   }
                   failure:^(NSURLRequest * _Nonnull request, NSHTTPURLResponse * _Nullable response, NSError * _Nonnull error) {
                       __strong __typeof(weakSelf)strongSelf = weakSelf;
                       //失败有failuerBlock就回调，
                        if ([strongSelf.af_activeImageDownloadReceipt.receiptID isEqual:downloadID]) {
                            if (failure) {
                                failure(request, response, error);
                            }
                            //置空回调对象
                            [strongSelf clearActiveDownloadInformation];
                        }
                   }];
        //赋值
        self.af_activeImageDownloadReceipt = receipt;
    }
}
```

这个方法，细节的地方可以关注注释，这里总结一下做了什么：  
1）去判断url是否为空，如果为空则取消task,调用如下方法:

**

```
//取消task
- (void)cancelImageDownloadTask {
    if (self.af_activeImageDownloadReceipt != nil) {
        //取消事件回调响应
        [[self.class sharedImageDownloader] cancelTaskForImageDownloadReceipt:self.af_activeImageDownloadReceipt];
        //置空
        [self clearActiveDownloadInformation];
     }
}
//置空
- (void)clearActiveDownloadInformation {
    self.af_activeImageDownloadReceipt = nil;
}
```

-   这里注意`cancelImageDownloadTask`中，调用了`self.af_activeImageDownloadReceipt`这么一个属性，看看定义的地方：

**

```
@interface UIImageView (_AFNetworking)
@property (readwrite, nonatomic, strong, setter = af_setActiveImageDownloadReceipt:) AFImageDownloadReceipt *af_activeImageDownloadReceipt;
@end
@implementation UIImageView (_AFNetworking)
//绑定属性 AFImageDownloadReceipt，就是一个事件响应的接受对象，包含一个task，一个uuid
 - (AFImageDownloadReceipt *)af_activeImageDownloadReceipt {
    return (AFImageDownloadReceipt *)objc_getAssociatedObject(self, @selector(af_activeImageDownloadReceipt));
}
//set
 - (void)af_setActiveImageDownloadReceipt:(AFImageDownloadReceipt *)imageDownloadReceipt {
    objc_setAssociatedObject(self, @selector(af_activeImageDownloadReceipt), imageDownloadReceipt, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end
```

我们现在是给`UIImageView`添加的一个类目，所以我们无法直接添加属性，而是使用的是runtime的方式来生成set和get方法生成了一个`AFImageDownloadReceipt`类型的属性。看过上文应该知道这个对象里面就一个task和一个UUID。这个属性就是我们这次下载任务相关联的信息。

2）然后做了一系列判断，见注释。  
3）然后生成了一个我们之前分析过得`AFImageDownloader`，然后去获取缓存，如果有缓存，则直接读缓存。还记得`AFImageDownloader`里也有一个读缓存的方法么？那个是和cachePolicy相关的，而这个是有缓存的话直接读取。不明白的可以回过头去看看。  
4）走到这说明没缓存了，然后就去用`AFImageDownloader`，我们之前讲过的方法，去请求图片。完成后，则调用成功或者失败的回调，并且置空属性`self.af_activeImageDownloadReceipt`，成功则设置图片。

除此之外还有一个取消这次任务的方法:

**

```
//取消task
- (void)cancelImageDownloadTask {
    if (self.af_activeImageDownloadReceipt != nil) {
        //取消事件回调响应
        [[self.class sharedImageDownloader] cancelTaskForImageDownloadReceipt:self.af_activeImageDownloadReceipt];
        //置空
        [self clearActiveDownloadInformation];
     }
}
```

其实也是去调用我们之前讲过的`AFImageDownloader`的取消方法。

这个类总共就这么几行代码，就完成了我们几乎没有人不用的，设置ImageView图片的方法。当然真正的难点在于`AFImageDownloader`和`AFAutoPurgingImageCache`。

###### 接下来我们来总结一下整个请求图片，缓存，然后设置图片的流程：

-   调用`- (void)setImageWithURL:(NSURL *)url;`时，我们生成  
    `AFImageDownloader`单例，并替我们请求数据。
-   而`AFImageDownloader`会生成一个`AFAutoPurgingImageCache`替我们缓存生成的数据。当然我们设置的时候，给`session`的`configuration`设置了一个系统级别的缓存`NSUrlCache`,这两者是互相独立工作的，互不影响的。
-   然后`AFImageDownloader`，就实现下载和协调`AFAutoPurgingImageCache`去缓存，还有一些取消下载的方法。然后通过回调把数据给到我们的类目`UIImageView+AFNetworking`,如果成功获取数据，则由类目设置上图片，整个流程结束。

经过这三个文件：  
`UIImageView+AFNetworking`、`AFImageDownloader`、`AFAutoPurgingImageCache`，至此整个设置网络图片的方法结束了。

###### 写在最后：

-   对于UIKit的总结，我们就到此为止了，其它部分的扩展，小伙伴们可以自行阅读，都很简单，基本上每个类200行左右的代码。核心功能基本上都是围绕`AFURLSessionManager`实现的。

  
 # AF2.x的核心实现，与AF3.x最新版本之间的对比，以及本系列的一个最终总结：AFNetworking到底做了什么？
 
![image.jpeg](https://p6-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/ed22e22150a94fe98f1dff01c23d3982~tplv-k3u1fbpfcp-watermark.image?)

除了UIKit扩展外，大概就是上述这么多类，其中最重要的有3个类：

1)`AFURLConnectionOperation`  
2)`AFHTTPRequestOperation`  
3)`AFHTTPRequestOperationManager`

-   大家都知道，AF2.x是基于`NSURLConnection`来封装的，而`NSURLConnection`的创建以及数据请求，就被封装在`AFURLConnectionOperation`这个类中。所以这个类基本上是AF2.x最底层也是最核心的类。
-   而`AFHTTPRequestOperation`是继承自`AFURLConnectionOperation`，对它父类一些方法做了些封装。
-   `AFHTTPRequestOperationManager`则是一个管家，去管理这些这些`operation`。

###### 我们接下来按照网络请求的流程去看看AF2.x的实现：

注：本文会涉及一些`NSOperationQueue`、`NSOperation`方面的知识，如果对这方面的内容不了解的话，可以先看看雷纯峰的这篇：  
[iOS 并发编程之 Operation Queues  
](https://link.jianshu.com/?t=http://blog.leichunfeng.com/blog/2015/07/29/ios-concurrency-programming-operation-queues/)

###### 首先，我们来写一个get或者post请求：

**

```
AFHTTPRequestOperationManager *manager = [AFHTTPRequestOperationManager manager];
[manager GET:url parameters:params
     success:^(AFHTTPRequestOperation *operation, id responseObject) {
         
     } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
         
     }];
```

就这么简单的几行代码，完成了一个网络请求。

接着我们来看看`AFHTTPRequestOperationManager`的初始化方法：

**

```
+ (instancetype)manager {
    return [[self alloc] initWithBaseURL:nil];
}

- (instancetype)init {
    return [self initWithBaseURL:nil];    
}
- (instancetype)initWithBaseURL:(NSURL *)url {
    self = [super init];
    if (!self) {
        return nil;
    }
    // Ensure terminal slash for baseURL path, so that NSURL +URLWithString:relativeToURL: works as expected
    if ([[url path] length] > 0 && ![[url absoluteString] hasSuffix:@"/"]) {
        url = [url URLByAppendingPathComponent:@""];
    }
    self.baseURL = url;
    self.requestSerializer = [AFHTTPRequestSerializer serializer];
    self.responseSerializer = [AFJSONResponseSerializer serializer];
    self.securityPolicy = [AFSecurityPolicy defaultPolicy];
    self.reachabilityManager = [AFNetworkReachabilityManager sharedManager];
    //用来调度所有请求的queue
    self.operationQueue = [[NSOperationQueue alloc] init];
    //是否做证书验证
    self.shouldUseCredentialStorage = YES;
    return self;
}
```

初始化方法很简单，基本和AF3.x类似，除了一下两点：  
1)设置了一个`operationQueue`，这个队列，用来调度里面所有的`operation`，在AF2.x中，每一个`operation`就是一个网络请求。  
2)设置`shouldUseCredentialStorage`为YES，这个后面会传给`operation`，`operation`会根据这个值，去返回给代理，系统是否做https的证书验证。

###### 然后我们来看看get方法：

**

```
- (AFHTTPRequestOperation *)GET:(NSString *)URLString
                     parameters:(id)parameters
                        success:(void (^)(AFHTTPRequestOperation *operation, id responseObject))success
                        failure:(void (^)(AFHTTPRequestOperation *operation, NSError *error))failure
{
    //拿到request
    NSMutableURLRequest *request = [self.requestSerializer requestWithMethod:@"GET" URLString:[[NSURL URLWithString:URLString relativeToURL:self.baseURL] absoluteString] parameters:parameters error:nil];
    
    AFHTTPRequestOperation *operation = [self HTTPRequestOperationWithRequest:request success:success failure:failure];

    [self.operationQueue addOperation:operation];
    return operation;
}
```

方法很简单，如下：  
1）用`self.requestSerializer`生成了一个request，至于如何生成，可以参考之前的文章，这里就不赘述了。  
2）生成了一个`AFHTTPRequestOperation`，然后把这个`operation`加到我们一开始创建的`queue`中。

其中创建`AFHTTPRequestOperation`方法如下：

**

```
- (AFHTTPRequestOperation *)HTTPRequestOperationWithRequest:(NSURLRequest *)request
                                                    success:(void (^)(AFHTTPRequestOperation *operation, id responseObject))success
                                                    failure:(void (^)(AFHTTPRequestOperation *operation, NSError *error))failure
{
    //创建自定义的AFHTTPRequestOperation
    AFHTTPRequestOperation *operation = [[AFHTTPRequestOperation alloc] initWithRequest:request];
    operation.responseSerializer = self.responseSerializer;
    operation.shouldUseCredentialStorage = self.shouldUseCredentialStorage;
    operation.credential = self.credential;
    //设置自定义的安全策略
    operation.securityPolicy = self.securityPolicy;

    [operation setCompletionBlockWithSuccess:success failure:failure];
    operation.completionQueue = self.completionQueue;
    operation.completionGroup = self.completionGroup;
    return operation;
}
```

方法创建了一个`AFHTTPRequestOperation`，并把自己的一些参数交给了这个`operation`处理。

###### 接着往里看：

**

```
- (instancetype)initWithRequest:(NSURLRequest *)urlRequest {
    self = [super initWithRequest:urlRequest];
    if (!self) {
        return nil;
    }

    self.responseSerializer = [AFHTTPResponseSerializer serializer];
    return self;
}
```

除了设置了一个`self.responseSerializer`，实际上是调用了父类，也是我们最核心的类`AFURLConnectionOperation`的初始化方法，首先我们要明确**这个类是继承自NSOperation的**，然后我们接着往下看：

**

```
//初始化
- (instancetype)initWithRequest:(NSURLRequest *)urlRequest {
    NSParameterAssert(urlRequest);

    self = [super init];
    if (!self) {
        return nil;
    }

    //设置为ready
    _state = AFOperationReadyState;
    //递归锁
    self.lock = [[NSRecursiveLock alloc] init];
    self.lock.name = kAFNetworkingLockName;
    self.runLoopModes = [NSSet setWithObject:NSRunLoopCommonModes];
    self.request = urlRequest;
    
    //是否应该咨询证书存储连接
    self.shouldUseCredentialStorage = YES;

    //https认证策略
    self.securityPolicy = [AFSecurityPolicy defaultPolicy];

    return self;
}
```

初始化方法中，初始化了一些属性，下面我们来简单的介绍一下这些属性：

1.  `_state`设置为`AFOperationReadyState` 准备就绪状态，这是个枚举：

**

```
typedef NS_ENUM(NSInteger, AFOperationState) {
    AFOperationPausedState      = -1,  //停止
    AFOperationReadyState       = 1,   //准备就绪
    AFOperationExecutingState   = 2,  //正在进行中
    AFOperationFinishedState    = 3,  //完成
};
```

这个`_state`标志着这个网络请求的状态，一共如上4种状态。这些状态其实对应着`operation`如下的状态：

**

```
//映射这个operation的各个状态
static inline NSString * AFKeyPathFromOperationState(AFOperationState state) {
    switch (state) {
        case AFOperationReadyState:
            return @"isReady";
        case AFOperationExecutingState:
            return @"isExecuting";
        case AFOperationFinishedState:
            return @"isFinished";
        case AFOperationPausedState:
            return @"isPaused";
        default: {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunreachable-code"
            return @"state";
#pragma clang diagnostic pop
        }
    }
}
```

并且还复写了这些属性的get方法，用来和自定义的state一一对应：

**

```
//复写这些方法，与自己的定义的state对应
 - (BOOL)isReady {
    return self.state == AFOperationReadyState && [super isReady];
}
 - (BOOL)isExecuting {
    return self.state == AFOperationExecutingState;
}
 - (BOOL)isFinished {
    return self.state == AFOperationFinishedState;
}
```

2.  `self.lock`这个锁是用来提供给本类一些数据操作的线程安全，至于为什么要用递归锁，是因为有些方法可能会存在递归调用的情况，例如有些需要锁的方法可能会在一个大的操作环中，形成递归。**而AF使用了递归锁，避免了这种情况下死锁的发生**。
2.  初始化了`self.runLoopModes`，默认为`NSRunLoopCommonModes`。
2.  生成了一个默认的 `self.securityPolicy`,关于这个policy执行的https认证，可以见楼主之前的文章。

这个类为了自定义`operation`的各种状态，而且更好的掌控它的生命周期，复写了`operation`的`start`方法，当这个`operation`在一个新线程被调度执行的时候，首先就调入这个`start`方法中，接下来我们它的实现看看：

**

```
- (void)start {
    [self.lock lock];
    
    //如果被取消了就调用取消的方法
    if ([self isCancelled]) {
        //在AF常驻线程中去执行
        [self performSelector:@selector(cancelConnection) onThread:[[self class] networkRequestThread] withObject:nil waitUntilDone:NO modes:[self.runLoopModes allObjects]];
    }
    //准备好了，才开始
    else if ([self isReady]) {
        //改变状态，开始执行
        self.state = AFOperationExecutingState;
        [self performSelector:@selector(operationDidStart) onThread:[[self class] networkRequestThread] withObject:nil waitUntilDone:NO modes:[self.runLoopModes allObjects]];
    }
    //注意，发起请求和取消请求都是在同一个线程！！包括回调都是在一个线程
    
    [self.lock unlock];
}
```

这个方法判断了当前的状态，是取消还是准备就绪，然后去调用了各自对应的方法。

-   注意这些方法都是在另外一个线程中去调用的，我们来看看这个线程：

**

```
 + (void)networkRequestThreadEntryPoint:(id)__unused object {
    @autoreleasepool {
        [[NSThread currentThread] setName:@"AFNetworking"];

        NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
        //添加端口，防止runloop直接退出
        [runLoop addPort:[NSMachPort port] forMode:NSDefaultRunLoopMode];
        [runLoop run];
    }
}
 + (NSThread *)networkRequestThread {
    static NSThread *_networkRequestThread = nil;
    static dispatch_once_t oncePredicate;
    dispatch_once(&oncePredicate, ^{
        _networkRequestThread = [[NSThread alloc] initWithTarget:self selector:@selector(networkRequestThreadEntryPoint:) object:nil];
        [_networkRequestThread start];
    });
    
    return _networkRequestThread;
}
```

这两个方法基本上是被许多人举例用过无数次了...

-   这是一个单例，用`NSThread`创建了一个线程，并且为这个线程添加了一个`runloop`，并且加了一个`NSMachPort`，来防止`runloop`直接退出。
-   **这条线程就是AF用来发起网络请求，并且接受网络请求回调的线程，仅仅就这一条线程**（到最后我们来讲为什么要这么做）。和我们之前讲的AF3.x发起请求，并且接受请求回调时的处理方式，遥相呼应。

我们接着来看如果准备就绪，start调用的方法：

**

```
//改变状态，开始执行
self.state = AFOperationExecutingState;
[self performSelector:@selector(operationDidStart) onThread:[[self class] networkRequestThread] withObject:nil waitUntilDone:NO modes:[self.runLoopModes allObjects]];
```

接着在常驻线程中,并且不阻塞的方式，在我们`self.runLoopModes`的模式下调用：

**

```
- (void)operationDidStart {
    [self.lock lock];
    //如果没取消
    if (![self isCancelled]) {
        //设置为startImmediately YES 请求发出，回调会加入到主线程的 Runloop 下，RunloopMode 会默认为 NSDefaultRunLoopMode
        self.connection = [[NSURLConnection alloc] initWithRequest:self.request delegate:self startImmediately:NO];
        
        NSRunLoop *runLoop = [NSRunLoop currentRunLoop];
        for (NSString *runLoopMode in self.runLoopModes) {
            //把connection和outputStream注册到当前线程runloop中去，只有这样，才能在这个线程中回调
            [self.connection scheduleInRunLoop:runLoop forMode:runLoopMode];
            [self.outputStream scheduleInRunLoop:runLoop forMode:runLoopMode];
        }
        //打开输出流
        [self.outputStream open];
        //开启请求
        [self.connection start];
    }
    [self.lock unlock];
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingOperationDidStartNotification object:self];
    });
}
```

这个方法做了以下几件事：

1.  首先这个方法创建了一个`NSURLConnection`，设置代理为自己，startImmediately为NO，至于这个参数干什么用的，我们来看看官方文档：

> startImmediately  
> YES if the connection should begin loading data immediately, otherwise NO. If you pass NO, the connection is not scheduled with a run loop. You can then schedule the connection in the run loop and mode of your choice by calling scheduleInRunLoop:forMode: .

大意是，这个值默认为YES，而且任务完成的结果会在主线程的runloop中回调。如果我们设置为NO，则需要调用我们下面看到的：

**

```
[self.connection scheduleInRunLoop:runLoop forMode:runLoopMode];
```

去注册一个runloop和mode，它会在我们指定的这个runloop所在的线程中回调结果。

2.  值得一提的是这里调用了:

```
[self.outputStream scheduleInRunLoop:runLoop forMode:runLoopMode];
```

这个`outputStream`在get方法中被初始化了：

```
 - (NSOutputStream *)outputStream {
    if (!_outputStream) {
        //一个写入到内存中的流，可以通过NSStreamDataWrittenToMemoryStreamKey拿到写入后的数据
        self.outputStream = [NSOutputStream outputStreamToMemory];
    }
    return _outputStream;
}
```

这里数据请求和拼接并没有用`NSMutableData`，而是用了`outputStream`，而且把写入的数据，放到内存中。

-   其实讲道理来说`outputStream`的优势在于下载大文件的时候，可以以流的形式，将文件直接保存到本地，**这样可以为我们节省很多的内存**，调用如下方法设置：
```
[NSOutputStream outputStreamToFileAtPath:@"filePath" append:YES];
```

-   但是这里是把流写入内存中，这样其实这个节省内存的意义已经不存在了。那为什么还要用呢？这里我猜测的是就是为了用它这个可以注册在某一个`runloop`的指定`mode`下。 虽然AF使用这个`outputStream`是肯定在这个常驻线程中的，不会有线程安全的问题。但是要注意它是被声明在.h中的：

**

```
@property (nonatomic, strong) NSOutputStream *outputStream;
```

难保外部不会在其他线程对这个数据做什么操作，所以它相对于`NSMutableData`作用就体现出来了，就算我们在外部其它线程中去操作它，也不会有线程安全的问题。

3.  这个`connection`开始执行了。
4.  到主线程发送一个任务开始执行的通知。
接下来网络请求开始执行了，就开始触发`connection`的代理方法了：

![image.jpeg](https://p9-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/41f81d171cd04bf7afeedeaf10850762~tplv-k3u1fbpfcp-watermark.image?)

AF2.x一共实现了如上这么多代理方法，这些代理方法，作用大部分和我们之前讲的`NSURLSession`的代理方法类似，我们只挑几个去讲，如果需要了解其他的方法作用，可以参考楼主之前的文章。

###### 重点讲下面这四个代理：

注意，有一点需要说明，我们之前是把connection注册在我们常驻线程的runloop中了，**所以以下所有的代理方法，都是在这仅有的一条常驻线程中回调。**

###### 第一个代理

**

```
//收到响应，响应头类似相关数据
- (void)connection:(NSURLConnection __unused *)connection
didReceiveResponse:(NSURLResponse *)response
{
    self.response = response;
}
```

没什么好说的，就是收到响应后，把response赋给自己的属性。

###### 第二个代理

**

```
//拼接获取到的数据
- (void)connection:(NSURLConnection __unused *)connection
    didReceiveData:(NSData *)data
{
    NSUInteger length = [data length];
    while (YES) {
        NSInteger totalNumberOfBytesWritten = 0;
        //如果outputStream 还有空余空间
        if ([self.outputStream hasSpaceAvailable]) {
           
            //创建一个buffer流缓冲区，大小为data的字节数
            const uint8_t *dataBuffer = (uint8_t *)[data bytes];

            NSInteger numberOfBytesWritten = 0;
           
            //当写的长度小于数据的长度，在循环里
            while (totalNumberOfBytesWritten < (NSInteger)length) {
                //往outputStream写数据，系统的方法，一次就写一部分，得循环写
                numberOfBytesWritten = [self.outputStream write:&dataBuffer[(NSUInteger)totalNumberOfBytesWritten] maxLength:(length - (NSUInteger)totalNumberOfBytesWritten)];
                //如果 numberOfBytesWritten写入失败了。跳出循环
                if (numberOfBytesWritten == -1) {
                    break;
                }
                //加上每次写的长度
                totalNumberOfBytesWritten += numberOfBytesWritten;
            }

            break;
        }
        
        //出错
        if (self.outputStream.streamError) {
            //取消connection
            [self.connection cancel];
            //调用失败的方法
            [self performSelector:@selector(connection:didFailWithError:) withObject:self.connection withObject:self.outputStream.streamError];
            return;
        }
    }

    //主线程回调下载数据大小
    dispatch_async(dispatch_get_main_queue(), ^{
        self.totalBytesRead += (long long)length;

        if (self.downloadProgress) {
            self.downloadProgress(length, self.totalBytesRead, self.response.expectedContentLength);
        }
    });
}
```

这个方法看起来长，其实容易理解而且简单，它只做了3件事：

1.  给`outputStream`拼接数据，具体如果拼接，大家可以读注释自行理解下。
1.  如果出错则调用：`connection:didFailWithError:`也就是网络请求失败的代理，我们一会下面就会讲。
1.  在主线程中回调下载进度。

###### 第三个代理

**

```
//完成了调用
- (void)connectionDidFinishLoading:(NSURLConnection __unused *)connection {

    //从outputStream中拿到数据 NSStreamDataWrittenToMemoryStreamKey写入到内存中的流
    self.responseData = [self.outputStream propertyForKey:NSStreamDataWrittenToMemoryStreamKey];

    //关闭outputStream
    [self.outputStream close];
    
    //如果响应数据已经有了，则outputStream置为nil
    if (self.responseData) {
       self.outputStream = nil;
    }
    //清空connection
    self.connection = nil;
    [self finish];
}
```

-   这个代理是任务完成之后调用。我们从`outputStream`拿到了最后下载数据，然后关闭置空了`outputStream`。并且清空了`connection`。调用了`finish`:

**

```
 - (void)finish {
    [self.lock lock];
    //修改状态
    self.state = AFOperationFinishedState;
    [self.lock unlock];

    //发送完成的通知
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:AFNetworkingOperationDidFinishNotification object:self];
    });
}
```

把当前任务状态改为已完成，并且到主线程发送任务完成的通知。，**这里我们设置状态为已完成。其实调用了我们本类复写的set的方法**（前面遗漏了，在这里补充）：

**

```
 - (void)setState:(AFOperationState)state {
    
    //判断从当前状态到另一个状态是不是合理，在加上现在是否取消。。大神的框架就是屌啊，这判断严谨的。。一层层
    if (!AFStateTransitionIsValid(self.state, state, [self isCancelled])) {
        return;
    }
    
    [self.lock lock];
    
    //拿到对应的父类管理当前线程周期的key
    NSString *oldStateKey = AFKeyPathFromOperationState(self.state);
    NSString *newStateKey = AFKeyPathFromOperationState(state);
    
    //发出KVO
    [self willChangeValueForKey:newStateKey];
    [self willChangeValueForKey:oldStateKey];
    _state = state;
    [self didChangeValueForKey:oldStateKey];
    [self didChangeValueForKey:newStateKey];
    [self.lock unlock];
}
```

这个方法改变`state`的时候，并且发送了`KVO`。大家了解`NSOperationQueue`就知道，如果对应的operation的属性`finnished`被设置为YES，则代表当前`operation`结束了，会把`operation`从队列中移除，并且调用`operation`的`completionBlock`。**这点很重要，因为我们请求到的数据就是从这个`completionBlock`中传递回去的**（下面接着讲这个完成Block，就能从这里对接上了）。

###### 第四个代理

**

```
//请求失败的回调，在cancel connection的时候，自己也主动调用了
- (void)connection:(NSURLConnection __unused *)connection
  didFailWithError:(NSError *)error
{
    //拿到error
    self.error = error;
    //关闭outputStream
    [self.outputStream close];
    //如果响应数据已经有了，则outputStream置为nil
    if (self.responseData) {
        self.outputStream = nil;
    }
    self.connection = nil;
    [self finish];
}
```

唯一需要说一下的就是这里给`self.error`赋值，之后完成Block会根据这个error，去判断这次请求是成功还是失败。

至此我们把`AFURLConnectionOperation`的业务主线讲完了。  


![]()

分割图.png

我们此时数据请求完了，数据在`self.responseData`中，接下来我们来看它是怎么回到我们手里的。  
我们回到`AFURLConnectionOperation`子类`AFHTTPRequestOperation`，有这么一个方法：

**

```
- (void)setCompletionBlockWithSuccess:(void (^)(AFHTTPRequestOperation *operation, id responseObject))success
                              failure:(void (^)(AFHTTPRequestOperation *operation, NSError *error))failure
{
    // completionBlock is manually nilled out in AFURLConnectionOperation to break the retain cycle.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
#pragma clang diagnostic ignored "-Wgnu"
    self.completionBlock = ^{
        if (self.completionGroup) {
            dispatch_group_enter(self.completionGroup);
        }

        dispatch_async(http_request_operation_processing_queue(), ^{
            if (self.error) {
                if (failure) {
                    dispatch_group_async(self.completionGroup ?: http_request_operation_completion_group(), self.completionQueue ?: dispatch_get_main_queue(), ^{
                        failure(self, self.error);
                    });
                }
            } else {
                id responseObject = self.responseObject;
                if (self.error) {
                    if (failure) {
                        dispatch_group_async(self.completionGroup ?: http_request_operation_completion_group(), self.completionQueue ?: dispatch_get_main_queue(), ^{
                            failure(self, self.error);
                        });
                    }
                } else {
                    if (success) {
                        dispatch_group_async(self.completionGroup ?: http_request_operation_completion_group(), self.completionQueue ?: dispatch_get_main_queue(), ^{
                            success(self, responseObject);
                        });
                    }
                }
            }

            if (self.completionGroup) {
                dispatch_group_leave(self.completionGroup);
            }
        });
    };
#pragma clang diagnostic pop
}
```

一开始我们在`AFHTTPRequestOperationManager`中是调用过这个方法的：

**

```
[operation setCompletionBlockWithSuccess:success failure:failure];
```

-   我们在把成功和失败的Block传给了这个方法。
-   这个方法也很好理解，就是设置我们之前提到过得`completionBlock`，**当自己数据请求完成，就会调用这个Block。然后我们在这个Block中调用传过来的成功或者失败的Block。** 如果error为空，说明请求成功，把数据传出去，否则为失败，把error信息传出。
-   这里也类似AF3.x，可以自定义一个完成组和完成队列。数据可以在我们自定义的完成组和队列中回调出去。
-   除此之外，还有一个有意思的地方：

**

```
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
#pragma clang diagnostic ignored "-Wgnu"
#pragma clang diagnostic pop
```

之前我们说过，这是在忽略编译器的一些警告。

-   `-Wgnu`就不说了，是忽略？：。
-   值得提下的是`-Warc-retain-cycles`，这里忽略了循环引用的警告。我们仔细看看就知道`self`持有了`completionBlock`，而`completionBlock`内部持有`self`。这里确实循环引用了。那么AF是如何解决这个循环引用的呢？

我们在回到`AFURLConnectionOperation`，还有一个方法我们之前没讲到，它复写了setCompletionBlock这个方法。

**

```
//复写setCompletionBlock
- (void)setCompletionBlock:(void (^)(void))block {
    [self.lock lock];
    if (!block) {
        [super setCompletionBlock:nil];
    } else {
        __weak __typeof(self)weakSelf = self;
        [super setCompletionBlock:^ {
            __strong __typeof(weakSelf)strongSelf = weakSelf;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wgnu"
            //看有没有自定义的完成组，否则用AF的组
            dispatch_group_t group = strongSelf.completionGroup ?: url_request_operation_completion_group();
            //看有没有自定义的完成queue，否则用主队列
            dispatch_queue_t queue = strongSelf.completionQueue ?: dispatch_get_main_queue();
#pragma clang diagnostic pop
            
            //调用设置的Block,在这个组和队列中
            dispatch_group_async(group, queue, ^{
                block();
            });

            //结束时候置nil，防止循环引用
            dispatch_group_notify(group, url_request_operation_completion_queue(), ^{
                [strongSelf setCompletionBlock:nil];
            });
        }];
    }
    [self.lock unlock];
}
```

注意，它在我们设置的block调用结束的时候，主动的调用:

**

```
[strongSelf setCompletionBlock:nil];
```

把Block置空，这样循环引用不复存在了。

好像我们还遗漏了一个东西，就是返回的数据做类型的解析。其实还真不是楼主故意这样东一块西一块的，AF2.x有些代码确实是这样零散。。当然仅仅是相对3.x来说。AFNetworking整体代码质量，以及架构思想已经强过绝大多数开源项目太多了。。这一点毋庸置疑。

###### 我们来接着看看数据解析在什么地方被调用的把：

**

```
- (id)responseObject {
    [self.lock lock];
    if (!_responseObject && [self isFinished] && !self.error) {
        NSError *error = nil;
        //做数据解析
        self.responseObject = [self.responseSerializer responseObjectForResponse:self.response data:self.responseData error:&error];
        if (error) {
            self.responseSerializationError = error;
        }
    }
    [self.lock unlock];
    return _responseObject;
}
```

`AFHTTPRequestOperation` 复写了 `responseObject` 的get方法，  
并且把数据按照我们需要的类型（json、xml等等）进行解析。至于如何解析，可以参考楼主之前AF系列的文章，这里就不赘述了。

有些小伙伴可能会说，楼主你是不是把`AFSecurityPolicy`给忘了啊，其实并没有，它被在 `AFURLConnectionOperation`中https认证的代理中被调用，我们之前系列的文章已经讲的非常详细了，感兴趣的朋友可以翻到前面的文章去看看。

至此，AF2.x整个业务流程就结束了。

接下来，我们来总结总结AF2.x整个业务请求的流程：

![image.jpeg](https://p1-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/5c0862a4d6b24f0a97c4ad8c82869c9d~tplv-k3u1fbpfcp-watermark.image?)
  ###### 如上图，我们来梳理一下整个流程：

-   最上层的是`AFHTTPRequestOperationManager`,我们调用它进行get、post等等各种类型的网络请求
-   然后它去调用`AFURLRequestSerialization`做request参数拼装。然后生成了一个`AFHTTPRequestOperation`实例，并把request交给它。然后把`AFHTTPRequestOperation`添加到一个`NSOperationQueue`中。
-   接着`AFHTTPRequestOperation`拿到request后，会去调用它的父类`AFURLConnectionOperation`的初始化方法，并且把相关参数交给它，除此之外，当父类完成数据请求后，它调用了`AFURLResponseSerialization`把数据解析成我们需要的格式（json、XML等等）。
-   最后就是我们AF最底层的类`AFURLConnectionOperation`，它去数据请求，并且如果是https请求，会在请求的相关代理中，调用`AFSecurityPolicy`做https认证。最后请求到的数据返回。

这就是AF2.x整个做网络请求的业务流程。

###### 我们来解决解决之前遗留下来的问题：为什么AF2.x需要一条常驻线程？

首先如果我们用`NSURLConnection`，我们为了获取请求结果有以下三种选择：

1.  在主线程调异步接口
1.  每一个请求用一个线程，对应一个runloop，然后等待结果回调。
1.  只用一条线程，一个runloop，所有结果回调在这个线程上。

很显然AF选择的是第3种方式，创建了一条常驻线程专门处理所有请求的回调事件，这个模型跟`nodejs`有点类似，我们来讨论讨论不选择另外两种方式的原因：

1.  试想如果我们所有的请求都在主线程中异步调用，好像没什么不可以？那为什么AF不这么做呢...在这里有两点原因（楼主个人总结的，有不同意见，欢迎讨论）：

-   第一是，如果我们放到主线程去做，势必要这么写：

**

```
 [[NSURLConnection alloc] initWithRequest:request delegate:self startImmediately:YES] 
```

这样NSURLConnection的回调会被放在主线程中`NSDefaultRunLoopMode`中，这样我们在其它类似`UITrackingRunLoopMode`模式下，我们是得不到网络请求的结果的，这显然不是我们想要的，那么我们势必需要调用：

**

```
[connection scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes]; 
```

把它加入````NSRunLoopCommonModes```中，试想如果有大量的网络请求，同时回调回来，就会影响我们的UI体验了。

-   另外一点原因是，如果我们请求数据返回，势必要进行数据解析，解析成我们需要的格式，那么这些解析都在主线程中做，给主线程增加额外的负担。  
    又或者我们回调回来开辟一个新的线程去做数据解析，那么我们有n个请求回来开辟n条线程带来的性能损耗，以及线程间切换带来的损耗，是不是一笔更大的开销。

所以综述两点原因，我们并不适合在主线程中回调。

2.  我们一开始就开辟n条线程去做请求，然后设置runloop保活住线程，等待结果回调。

-   其实看到这，大家想想都觉得这个方法很傻，为了等待不确定的请求结果，阻塞住线程，白白浪费n条线程的开销。

综上所述，这就是**AF2.x需要一条常驻线程的原因了**。

###### 至此我们把AF2.x核心流程分析完

接着到我们本系列一个最终总结了: **AFNetworking到底做了什么？**

-   相信如果从头看到尾的小伙伴，心里都有了一个属于自己的答案。其实在楼主心里，实在不想去总结它，因为`AFNetworking`中凝聚了太多大牛的思想，根本不是你看完几遍源码所能去议论的。但是想想也知道，如果我说不总结，估计有些看到这的朋友杀人的心都有...
-   所以我还是赶鸭子上架，来总结总结它。

###### AFNetworking的作用总结：

一. 首先我们需要明确一点的是：  
**相对于AFNetworking2.x，AFNetworking3.x确实没那么有用了。** AFNetworking之前的核心作用就是为了帮我们去调度所有的请求。但是最核心地方却被苹果的`NSURLSession`给借鉴过去了，嗯...是借鉴。这些请求的调度，现在完全由`NSURLSession`给做了，AFNetworking3.x的作用被大大的削弱了。  
二. 但是除此之外，其实它还是很有用的：

1.  **首先它帮我们做了各种请求方式request的拼接。** 想想如果我们用`NSURLSession`，我们去做请求，是不是还得自己去考虑各种请求方式下，拼接参数的问题。

-   **它还帮我们做了一些公用参数（session级别的），和一些私用参数（task级别的）的分离**。它用Block的形式，支持我们自定义一些代理方法，如果没有实现的话，AF还帮我们做了一些默认的处理。而如果我们用`NSURLSession`的话，还得参照AF这么一套代理转发的架构模式去封装。
-   **它帮我们做了自定义的https认证处理**。看过楼主之前那篇[AFNetworking之于https认证](https://www.jianshu.com/p/a84237b07611)的朋友就知道，如果我们自己用`NSURLSession`实现那几种自定义认证，需要多写多少代码...
-   **对于请求到的数据，AF帮我们做了各种格式的数据解析，并且支持我们设置自定义的code范围，自定义的数据方式**。如果不在这些范围中，则直接调用失败block。如果用`NSURLSession`呢？这些都自己去写吧...（你要是做过各种除json外其他的数据解析,就会知道这里面坑有多少...）
-   **对于成功和失败的回调处理。** AF帮我们在数据请求到，到回调给用户之间，做了各种错误的判断，保证了成功和失败的回调，界限清晰。在这过程中，AF帮我们做了太多的容错处理，而`NSURLSession`呢？只给了一个完成的回调，我们得多做多少判断，才能拿到一个确定能正常显示的数据？
-   ......
-   ...

光是这些网络请求的业务逻辑，AF帮我们做的就太多太多，当然还远不仅于此。它用凝聚着许多大牛的经验方式，帮我在有些处理中做了最优的选择，比如我们之前说到的，回调线程数设置为1的问题...帮我们绕开了很多的坑，比如系统内部并行创建`task`导致id不唯一等等...

三. 而如果我们需要一些UIKit的扩展，AF则提供了最稳定，而且最优化实现方式：

-   就比如之前说到过得那个状态栏小菊花，如果是我们自己去做，得多写多少代码，而且实现的还没有AF那样质量高。
-   又或者`AFImageDownloader`，它对于组图片之间的下载协调，以及缓存使用的之间线程调度。对于线程，锁，以及性能各方面权衡，找出最优化的处理方式，试问小伙伴们自己基于`NSURLSession`去写，能到做几分...

所以最后的结论是：**AFNetworking虽然变弱了，但是它还是很有用的。** 用它真的不仅仅是习惯，而是因为它确实帮我们做了太多。