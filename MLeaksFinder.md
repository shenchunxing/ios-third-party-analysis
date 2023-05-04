# MLeaksFinder
从`UIViewController`入手，当一个`UIViewController`被pop或者dismiss后，该VC包括它的子View，或者子view的子view等等都会很快的被释放（除非设计成单例，或者持有它的强引用，但一般很少这样做）。于是，我们只需在一个`ViewController`被pop或者dismiss一小段时间后，看看该VC，它的subViews等是否还存在。

通过`UIViewController+MemoryLeak.h`的`load`方法可以看出，交换了`viewDidDisappear:、viewWillAppear:、dismissViewControllerAnimated:completion:`三个方法。

下面分析一下方法`viewDidDisappear：`

```
- (void)swizzled_viewDidDisappear:(BOOL)animated {
    [self swizzled_viewDidDisappear:animated];
    //关联值pop已经被设置，说明即将释放内存
    if ([objc_getAssociatedObject(self, kHasBeenPoppedKey) boolValue]) {
        [self willDealloc];
    }
}
复制代码
```

调用了当前类的`-willDealloc`方法，

```
- (BOOL)willDealloc {
    if (![super willDealloc]) {
        return NO;
    }
    //释放子控制器
    [self willReleaseChildren:self.childViewControllers];
    //释放presentedViewController
    [self willReleaseChild:self.presentedViewController];
    
    //释放当前view
    if (self.isViewLoaded) {
        [self willReleaseChild:self.view];
    }
    
    return YES;
}
复制代码
```

通过super调用父类的`-willDealloc`，重点说明一下该方法

  ```
- (BOOL)willDealloc {
    NSString *className = NSStringFromClass([self class]);
    //当前类名包含在白名单内，不需要检查内存泄露
    if ([[NSObject classNamesWhitelist] containsObject:className])
        return NO;
    
    //如果是sendAction的方式，不需要检测内存泄漏
    NSNumber *senderPtr = objc_getAssociatedObject([UIApplication sharedApplication], kLatestSenderKey);
    if ([senderPtr isEqualToNumber:@((uintptr_t)self)])
        return NO;
    
    //延迟2秒执行
    __weak id weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong id strongSelf = weakSelf;
        [strongSelf assertNotDealloc];
    });
    
    return YES;
}
复制代码
```

-   第一步：首先通过`classNamesWhitelist`检测白名单，如果对象在白名单之中，便`return NO`，即不是内存泄漏。

构建基础白名单时，使用了单例，确保只有一个，这个方法是私有的。

```
+ (NSMutableSet *)classNamesWhitelist {
    static NSMutableSet *whitelist = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        whitelist = [NSMutableSet setWithObjects:
                     @"UIFieldEditor", // UIAlertControllerTextField
                     @"UINavigationBar",
                     @"_UIAlertControllerActionView",
                     @"_UIVisualEffectBackdropView",
                     nil];
        
        // System's bug since iOS 10 and not fixed yet up to this ci.
        NSString *systemVersion = [UIDevice currentDevice].systemVersion;
        if ([systemVersion compare:@"10.0" options:NSNumericSearch] != NSOrderedAscending) {
            [whitelist addObject:@"UISwitch"];
        }
    });
    return whitelist;
}
复制代码
```

同时，在`NSObject+MemoryLeak.h`文件中提供了一个方法，使得我们可以自定义白名单

```
+ (void)addClassNamesToWhitelist:(NSArray *)classNames {
    [[self classNamesWhitelist] addObjectsFromArray:classNames];
}
```
-   第二步：判断该对象是否是上一次发送action的对象，是的话，不进行内存检测 （也就是指调用sendAction:to:from:forEvent方法，这个是不需要进行内存检测）

```
    NSNumber *senderPtr = objc_getAssociatedObject([UIApplication sharedApplication], kLatestSenderKey);
    if ([senderPtr isEqualToNumber:@((uintptr_t)self)])
        return NO;
```
-   第三步：**弱指针指向self，2s延迟，然后通过这个弱指针调用`-assertNotDealloc`，若被释放，给nil发消息直接返回，不触发`-assertNotDealloc`方法，认为已经释放；如果它没有被释放（泄漏了），`-assertNotDealloc`就会被调用**

```
__weak id weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong id strongSelf = weakSelf;
        //2秒后判断对象是否还存在，存在的话说明存在内存泄露，放调用成功，不存在就是nil
        [strongSelf assertNotDealloc];
    });
```
`assertNotDealloc`方法放在最后再谈

接着会调用`-willReleaseChildren、-willReleaseChild`遍历该对象的子对象，判断是否释放

```
- (void)willReleaseChild:(id)child {
    if (!child) {
        return;
    }
    
    [self willReleaseChildren:@[ child ]];
}

- (void)willReleaseChildren:(NSArray *)children {
    NSArray *viewStack = [self viewStack];
    NSSet *parentPtrs = [self parentPtrs];
    for (id child in children) {
        NSString *className = NSStringFromClass([child class]);
        [child setViewStack:[viewStack arrayByAddingObject:className]];
        [child setParentPtrs:[parentPtrs setByAddingObject:@((uintptr_t)child)]];
        [child willDealloc];
    }
}
```
通过代码可以看出，`-willReleaseChildren`拿到当前对象的`viewStack`和`parentPtrs`，然后遍历`children`，为每个子对象设置`viewStack`和`parentPtrs`。 然后会执行`[child willDealloc]`，去检测子类。

这里结合源码看下`viewStack`与`parentPtrs`的get和set实现方法

```
- (NSArray *)viewStack {
    NSArray *viewStack = objc_getAssociatedObject(self, kViewStackKey);
    if (viewStack) {
        return viewStack;
    }
    
    NSString *className = NSStringFromClass([self class]);
    return @[ className ];
}

- (void)setViewStack:(NSArray *)viewStack {
    objc_setAssociatedObject(self, kViewStackKey, viewStack, OBJC_ASSOCIATION_RETAIN);
}

- (NSSet *)parentPtrs {
    NSSet *parentPtrs = objc_getAssociatedObject(self, kParentPtrsKey);
    if (!parentPtrs) {
        parentPtrs = [[NSSet alloc] initWithObjects:@((uintptr_t)self), nil];
    }
    return parentPtrs;
}

- (void)setParentPtrs:(NSSet *)parentPtrs {
    objc_setAssociatedObject(self, kParentPtrsKey, parentPtrs, OBJC_ASSOCIATION_RETAIN);
}
复制代码
```

两者实现方法类似，通过运行时机制，即利用关联对象给一个类添加属性信息，只不过前者是一个数组，后者是一个集合。

关联对象`parentPtrs`，会在`-assertNotDealloc`中，会判断当前对象是否与父节点集合有交集。下面仔细看下`-assertNotDealloc`方法

```
- (void)assertNotDealloc {
    if ([MLeakedObjectProxy isAnyObjectLeakedAtPtrs:[self parentPtrs]]) {
        return;
    }
    [MLeakedObjectProxy addLeakedObject:self];
    
    NSString *className = NSStringFromClass([self class]);
    NSLog(@"Possibly Memory Leak.\nIn case that %@ should not be dealloced, override -willDealloc in %@ by returning NO.\nView-ViewController stack: %@", className, className, [self viewStack]);
}
复制代码
```

这里调用了`MLeakedObjectProxy`类中的`+isAnyObjectLeakedAtPtrs`

```
+ (BOOL)isAnyObjectLeakedAtPtrs:(NSSet *)ptrs {
    NSAssert([NSThread isMainThread], @"Must be in main thread.");
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        leakedObjectPtrs = [[NSMutableSet alloc] init];
    });
    
    if (!ptrs.count) {
        return NO;
    }
    //检测是否有交集，有交集说明没有内存泄漏
    if ([leakedObjectPtrs intersectsSet:ptrs]) {
        return YES;
    } else {
        return NO;
    }
}
复制代码
```

该方法中初始化了一个单例对象`leakedObjectPtrs`，通过`leakedObjectPtrs`与传入的参数`[self parentPtrs]`检测他们的交集，传入的 ptrs 中是否是泄露的对象。

 如果上述方法返回的是NO，则继续调用下面方法`+addLeakedObject`

```
+ (void)addLeakedObject:(id)object {
    NSAssert([NSThread isMainThread], @"Must be in main thread.");
    
    MLeakedObjectProxy *proxy = [[MLeakedObjectProxy alloc] init];
    proxy.object = object;
    proxy.objectPtr = @((uintptr_t)object);
    proxy.viewStack = [object viewStack];
    static const void *const kLeakedObjectProxyKey = &kLeakedObjectProxyKey;
    objc_setAssociatedObject(object, kLeakedObjectProxyKey, proxy, OBJC_ASSOCIATION_RETAIN);
    
    [leakedObjectPtrs addObject:proxy.objectPtr];
    
#if _INTERNAL_MLF_RC_ENABLED
    [MLeaksMessenger alertWithTitle:@"Memory Leak"
                            message:[NSString stringWithFormat:@"%@", proxy.viewStack]
                           delegate:proxy
              additionalButtonTitle:@"Retain Cycle"];
#else
    [MLeaksMessenger alertWithTitle:@"Memory Leak"
                            message:[NSString stringWithFormat:@"%@", proxy.viewStack]];
#endif
}
复制代码
```

第一步：构造`MLeakedObjectProxy`对象，给传入的泄漏对象 `object` 关联一个代理即 `proxy`

第二步：通过`objc_setAssociatedObject(object, kLeakedObjectProxyKey, proxy, OBJC_ASSOCIATION_RETAIN)`方法，`object`强持有`proxy`， `proxy`若持有`object`，如果`object`释放，`proxy`也会释放

第三步：存储 `proxy.objectPtr`（实际是对象地址）到集合 `leakedObjectPtrs` 里边

第四步：弹框 `AlertView`若 `_INTERNAL_MLF_RC_ENABLED == 1`，则弹框会增加检测循环引用的选项；若 `_INTERNAL_MLF_RC_ENABLED == 0`，则仅展示堆栈信息。

对于`MLeakedObjectProxy`类而言，是检测到内存泄漏才产生的，作为泄漏对象的属性存在的，如果泄漏的对象被释放，那么`MLeakedObjectProxy`也会被释放，则调用`-dealloc`函数

集合`leakedObjectPtrs`中移除该对象地址，同时再次弹窗，提示该对象已经释放了

```
- (void)dealloc {
    NSNumber *objectPtr = _objectPtr;
    NSArray *viewStack = _viewStack;
    dispatch_async(dispatch_get_main_queue(), ^{
        [leakedObjectPtrs removeObject:objectPtr];
        [MLeaksMessenger alertWithTitle:@"Object Deallocated"
                                message:[NSString stringWithFormat:@"%@", viewStack]];
    });
}
复制代码
```
当点击弹框中的检测循环引用按钮时，相关的操作都在下面 `AlertView` 的代理方法里边，即异步地通过 `FBRetainCycleDetector` 检测循环引用，然后回到主线程，利用弹框提示用户检测结果。
  
![image.png](https://p1-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/b3bc22178d2049e8a4f2de2853017b87~tplv-k3u1fbpfcp-watermark.image?)
同时控制台会有相关输出


![image.png](https://p6-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/1fbca67a84a8443fb71bc3f9c2962b06~tplv-k3u1fbpfcp-watermark.image?)

可以快速定位到内存泄漏的位置。

另外，针对一些特殊情况：

-   有时候即使调了pop，dismiss，也不会被释放，比如单例。如果某个特别的对象不会被释放，开发者可以重写`willDealloc`，`return NO`

-   部分系统的view是不会被释放的，需要建立白名单

-   `MLeaksFinder`支持手动扩展，通过`MLCheck()`宏来检测其他类型的对象的内存泄露，为传进来的对象建立View-ViewController stack信息

-   结合`FBRetainCycleDetector`一起使用时：

    -   内存泄漏不一定是循环引用造成的
    -   有的循环引用 `FBRetainCycleDetector` 不一定能找出
