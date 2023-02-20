//
//  MASExampleAutoHeightViewController.m
//  Masonry iOS Examples
//
//  Created by 沈春兴 on 2022/6/24.
//  Copyright © 2022 Jonas Budelmann. All rights reserved.
//

#import "MASExampleAutoHeightViewController.h"
#import "View+MASAdditions.h"

@class ListCell,ListModel;

@interface MASExampleAutoHeightViewController ()<UITableViewDelegate, UITableViewDataSource>
{
    UITableView *listTableView;
    NSMutableArray *dataArray;
}
@end

static NSString *identifier = @"listCell";

@interface ListCell()
@property (nonatomic, strong) ListModel *model;
@property (nonatomic, strong) UILabel *titleLb;
@property (nonatomic, strong) UILabel *timeLb;
@property (nonatomic, strong) UILabel *rightLab;
@property (nonatomic, strong) UISwitch *sw;
@end

@interface ListModel ()

@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *time;
@property (nonatomic, copy) NSString *des;
@end

@implementation MASExampleAutoHeightViewController

- (id)init {
    self = [super init];
    if (!self) return nil;

    self.title = @"Auto Height";

    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];

    NSArray *titles = @[@"跑步与不跑步的人，在1天、1月甚至1年来看都没什么了不起的差距；但在每5年来看的时候，就是身体和精神状态的巨大分野；等到了10年再看的时候，也许就是一种人生对另一种人生不可企及的鸿沟。",@"读过的书不会成为过眼烟云，它们会潜在气质里、在谈吐上、在胸襟的无涯，当然也可能显露在生活和文字中。",@"而定投和跑步、读书一样，都是人生中最简单却又最美好的事情。",@"彼得·林奇曾说：投资者如果能够不为经济形式焦虑，不看重市场状况，只是按照固定的计划进行投资，其成绩往往好于那些成天研究，试图预测市场并据此买卖",@"22222222222222222222222222222222222222222222222222222222222222222222222222222222",@"333333333333333333333333333333333333333333333333333333333333333333333333333333333333",@"44444444444444444444444444444444444444444444444444"
    @"555555555555555555555555555555555555555555555555555555555555555555555555",@"6666666666666666666666666666666666666666666666666666666666666666666666",@"7777777777777777777777777777777777777777777777777777777777777777777777777777777777777",@"888888888888888888888888888888888888888888888888888888888888888"];
dataArray = [NSMutableArray array];

for (int i = 0; i < titles.count; i++)
{
    ListModel *model = [[ListModel alloc] init];
    model.title = titles[i];
    model.time = @"2017-02-09";
    model.des = [NSString stringWithFormat:@"10000%d",i];
    [dataArray addObject:model];
}

    listTableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    listTableView.delegate = self;
    listTableView.dataSource = self;
    listTableView.estimatedRowHeight = 60; //估算高度
    listTableView.rowHeight = UITableViewAutomaticDimension; //自动适应高度
    [listTableView registerClass:[ListCell class] forCellReuseIdentifier:identifier];
    [self.view addSubview:listTableView];
    [listTableView mas_makeConstraints:^(MASConstraintMaker *make) {
    make.edges.equalTo(self.view);
    }];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    ListCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    cell.model = dataArray[indexPath.row];

    return cell;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return dataArray.count;
}

@end


@implementation ListCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    
    [self.titleLb mas_makeConstraints:^(MASConstraintMaker *make) {
        make.left.top.equalTo(self.contentView).offset(10);
        make.right.equalTo(self.contentView).offset(-10);
    }];

    [self.timeLb mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(_titleLb.mas_bottom).offset(10);
        make.left.equalTo(self.contentView).offset(10);
        make.bottom.equalTo(self.contentView).offset(-10);
    }];
    
    [self.rightLab mas_makeConstraints:^(MASConstraintMaker *make) {
        make.top.equalTo(_titleLb.mas_bottom).offset(10);
        make.left.equalTo(self.timeLb.mas_right).offset(20);
        make.bottom.equalTo(self.contentView).offset(-10);
        make.left.equalTo(self.contentView).offset(10).priorityLow();
    }];
    
    [self.sw mas_makeConstraints:^(MASConstraintMaker *make) {
        make.right.equalTo(self.contentView).offset(-10);
        make.bottom.equalTo(self.contentView).offset(-10);
        make.width.height.equalTo(50);
    }];
    
    return self;
}

#pragma mark - lazy load
- (UILabel *)titleLb
{
    if (!_titleLb)
    {
     _titleLb = [[UILabel alloc] init];
     _titleLb.numberOfLines = 0;
        [self.contentView addSubview:_titleLb];
    }

    return _titleLb;
}

- (UILabel *)timeLb
{
    if (!_timeLb)
    {
        _timeLb = [[UILabel alloc] init];
        _timeLb.numberOfLines = 0;
        [self.contentView addSubview:_timeLb];
    }

    return _timeLb;
}

- (UILabel *)rightLab
{
    if (!_rightLab)
    {
        _rightLab = [[UILabel alloc] init];
        [self.contentView addSubview:_rightLab];
    }

    return _rightLab;
}

- (UISwitch *)sw {
    if (!_sw) {
        _sw = [[UISwitch alloc] init];
        _sw.on = YES;
        [self.contentView addSubview:_sw];
        [_sw addTarget:self action:@selector(swAction:) forControlEvents:UIControlEventValueChanged];
    }
    return _sw;
}

- (void)swAction:(UISwitch *)sw {
    if (sw.isOn) {
        [self.contentView addSubview:self.timeLb];
    } else {
        [self.timeLb removeFromSuperview];
    }
}

#pragma mark - set
- (void)setModel:(ListModel *)model
{
     _model = model;

    self.titleLb.text = _model.title;
    self.timeLb.text = _model.time;
    self.rightLab.text = model.des;

}

@end

@implementation ListModel


@end

