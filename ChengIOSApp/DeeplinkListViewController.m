#import "DeeplinkListViewController.h"

@interface DeeplinkListViewController ()
@property (nonatomic, copy) NSArray<NSDictionary *> *items;
@end

@implementation DeeplinkListViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Deeplink";
    self.items = @[
        @{@"title": @"Random Info May", @"url": @"chengios://random-identity"},
        @{@"title": @"Random Toan Bo", @"url": @"chengios://random-all"},
        @{@"title": @"Random Viet Nam", @"url": @"chengios://random-all?region=vn"},
        @{@"title": @"Random United States", @"url": @"chengios://random-all?region=us"},
        @{@"title": @"Random Korea", @"url": @"chengios://random-all?region=kr"},
        @{@"title": @"Random Japan", @"url": @"chengios://random-all?region=jp"},
        @{@"title": @"Random United Kingdom", @"url": @"chengios://random-all?region=gb"},
        @{@"title": @"Random Thailand", @"url": @"chengios://random-all?region=th"},
        @{@"title": @"Random Singapore", @"url": @"chengios://random-all?region=sg"},
        @{@"title": @"Random Australia", @"url": @"chengios://random-all?region=au"},
        @{@"title": @"Random Taiwan", @"url": @"chengios://random-all?region=tw"},
        @{@"title": @"Random theo vung", @"url": @"chengios://regions"},
        @{@"title": @"Change Apps", @"url": @"chengios://apps"},
        @{@"title": @"Xem ho so", @"url": @"chengios://profile"},
        @{@"title": @"Sao chep ho so", @"url": @"chengios://copy"},
        @{@"title": @"Mo Settings", @"url": @"chengios://settings"},
        @{@"title": @"Quan ly Backup", @"url": @"chengios://backup"},
        @{@"title": @"Backup ho so", @"url": @"chengios://backup-profile"},
        @{@"title": @"Backup ho so + data app", @"url": @"chengios://backup-apps"},
        @{@"title": @"Backup 1 app (Facebook)", @"url": @"chengios://backup-apps?bundle=com.facebook.Facebook"},
        @{@"title": @"Restore backup moi nhat", @"url": @"chengios://restore-latest"},
        @{@"title": @"Restore + data moi nhat", @"url": @"chengios://restore-latest?data=1"},
        @{@"title": @"Xoa sach data app da chon", @"url": @"chengios://erase-apps"},
        @{@"title": @"Xoa data Facebook", @"url": @"chengios://erase?bundle=com.facebook.Facebook"},
        @{@"title": @"Xoa toan bo app + Safari", @"url": @"chengios://erase-device"},
        @{@"title": @"Xoa app da chon + Random Toan Bo", @"url": @"chengios://erase-random-all"},
        @{@"title": @"Xoa toan bo + Random Toan Bo", @"url": @"chengios://erase-device-random"},
        @{@"title": @"Respring", @"url": @"chengios://respring"},
        @{@"title": @"Random silent", @"url": @"chengios://random-all?silent=1"}
    ];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (NSInteger)self.items.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return @"An 1 dong de sao chep URL. Shortcuts: thao tac Mo URL.";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"d"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"d"];
        cell.detailTextLabel.numberOfLines = 2;
        cell.detailTextLabel.adjustsFontSizeToFitWidth = YES;
    }
    NSDictionary *item = self.items[indexPath.row];
    cell.textLabel.text = item[@"title"];
    cell.detailTextLabel.text = item[@"url"];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSString *url = self.items[indexPath.row][@"url"];
    [UIPasteboard generalPasteboard].string = url;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Da sao chep"
                                                                   message:url
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
