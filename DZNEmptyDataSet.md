# DZNEmptyDataSet
https://github.com/dzenbot/DZNEmptyDataSet

项目中详细使用参考官方demo：
https://github.com/dzenbot/DZNEmptyDataSet/tree/master/DZNEmptyDataSet/Applications

![image.png](https://p9-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/cf8bd10d241a472788ff928d38d0a5b7~tplv-k3u1fbpfcp-watermark.image?)


对scrollView、tableView、collectionView设置
```
self.tableView.emptyDataSetSource = self;
self.tableView.emptyDataSetDelegate = self;
```
根据项目定制实现空视图，实现各种代理，常见的几个方法

```
/**
  数据为空时，显示的提示标语
 */
- (nullable NSAttributedString *)titleForEmptyDataSet:(UIScrollView *)scrollView;

/**
  数据为空时，显示的提示显示内容
 */
- (nullable NSAttributedString *)descriptionForEmptyDataSet:(UIScrollView *)scrollView;

/**
  数据为空时，显示的提示显示图像
 */
- (nullable UIImage *)imageForEmptyDataSet:(UIScrollView *)scrollView;
```
实现原理：关键的意思就运用了runtime特性，替换掉UITableView 或者 UICollectionView 的reloadData 函数
```
 // Swizzle by injecting additional implementation
 Method method = class_getInstanceMethod(baseClass, selector);
 IMP dzn_newImplementation = method_setImplementation(method, (IMP)dzn_original_implementation);
```
拦截该方法之后在适当的时机计算datasource的数量，如果总数量为空就像是相应的视图，否则还是按照原本的处理逻辑
```
- (NSInteger)dzn_itemsCount
{
    NSInteger items = 0;
    
    // UIScollView doesn't respond to 'dataSource' so let's exit
    if (![self respondsToSelector:@selector(dataSource)]) {
        return items;
    }
    
    // UITableView support
    if ([self isKindOfClass:[UITableView class]]) {
        
        UITableView *tableView = (UITableView *)self;
        id <UITableViewDataSource> dataSource = tableView.dataSource;
        
        NSInteger sections = 1;
        
        if (dataSource && [dataSource respondsToSelector:@selector(numberOfSectionsInTableView:)]) {
            sections = [dataSource numberOfSectionsInTableView:tableView];
        }
        
        if (dataSource && [dataSource respondsToSelector:@selector(tableView:numberOfRowsInSection:)]) {
            for (NSInteger section = 0; section < sections; section++) {
                items += [dataSource tableView:tableView numberOfRowsInSection:section];
            }
        }
    }
    // UICollectionView support
    else if ([self isKindOfClass:[UICollectionView class]]) {
        
        UICollectionView *collectionView = (UICollectionView *)self;
        id <UICollectionViewDataSource> dataSource = collectionView.dataSource;

        NSInteger sections = 1;
        
        if (dataSource && [dataSource respondsToSelector:@selector(numberOfSectionsInCollectionView:)]) {
            sections = [dataSource numberOfSectionsInCollectionView:collectionView];
        }
        
        if (dataSource && [dataSource respondsToSelector:@selector(collectionView:numberOfItemsInSection:)]) {
            for (NSInteger section = 0; section < sections; section++) {
                items += [dataSource collectionView:collectionView numberOfItemsInSection:section];
            }
        }
    }
    
    return items;
}
```





对scrollView、tableView、collectionView设置
```
self.tableView.emptyDataSetSource = self;
self.tableView.emptyDataSetDelegate = self;
```
根据项目定制实现空视图，实现各种代理，常见的几个方法

```
/**
  数据为空时，显示的提示标语
 */
- (nullable NSAttributedString *)titleForEmptyDataSet:(UIScrollView *)scrollView;

/**
  数据为空时，显示的提示显示内容
 */
- (nullable NSAttributedString *)descriptionForEmptyDataSet:(UIScrollView *)scrollView;

/**
  数据为空时，显示的提示显示图像
 */
- (nullable UIImage *)imageForEmptyDataSet:(UIScrollView *)scrollView;
```
实现原理：关键的意思就运用了runtime特性，替换掉UITableView 或者 UICollectionView 的reloadData 函数
```
 // Swizzle by injecting additional implementation
 Method method = class_getInstanceMethod(baseClass, selector);
 IMP dzn_newImplementation = method_setImplementation(method, (IMP)dzn_original_implementation);
```
拦截该方法之后在适当的时机计算datasource的数量，如果总数量为空就像是相应的视图，否则还是按照原本的处理逻辑
```
- (NSInteger)dzn_itemsCount
{
    NSInteger items = 0;
    
    // UIScollView doesn't respond to 'dataSource' so let's exit
    if (![self respondsToSelector:@selector(dataSource)]) {
        return items;
    }
    
    // UITableView support
    if ([self isKindOfClass:[UITableView class]]) {
        
        UITableView *tableView = (UITableView *)self;
        id <UITableViewDataSource> dataSource = tableView.dataSource;
        
        NSInteger sections = 1;
        
        if (dataSource && [dataSource respondsToSelector:@selector(numberOfSectionsInTableView:)]) {
            sections = [dataSource numberOfSectionsInTableView:tableView];
        }
        
        if (dataSource && [dataSource respondsToSelector:@selector(tableView:numberOfRowsInSection:)]) {
            for (NSInteger section = 0; section < sections; section++) {
                items += [dataSource tableView:tableView numberOfRowsInSection:section];
            }
        }
    }
    // UICollectionView support
    else if ([self isKindOfClass:[UICollectionView class]]) {
        
        UICollectionView *collectionView = (UICollectionView *)self;
        id <UICollectionViewDataSource> dataSource = collectionView.dataSource;

        NSInteger sections = 1;
        
        if (dataSource && [dataSource respondsToSelector:@selector(numberOfSectionsInCollectionView:)]) {
            sections = [dataSource numberOfSectionsInCollectionView:collectionView];
        }
        
        if (dataSource && [dataSource respondsToSelector:@selector(collectionView:numberOfItemsInSection:)]) {
            for (NSInteger section = 0; section < sections; section++) {
                items += [dataSource collectionView:collectionView numberOfItemsInSection:section];
            }
        }
    }
    
    return items;
}
```


