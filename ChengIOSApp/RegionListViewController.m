#import "RegionListViewController.h"
#import "../ChengIOSPrefs/ChengIOSProfiles.h"

@implementation RegionListViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Random theo vung";
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (NSInteger)ChengIOSRegionChoices().count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return @"Chon vung de Random Toan Bo: locale, nha mang, GPS, Wi-Fi, IPv6/LAN theo vung do. Web van thay IP cong cong that (can VPN neu muon IP US/KR).";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"r"];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:@"r"];
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    NSDictionary *item = ChengIOSRegionChoices()[indexPath.row];
    cell.textLabel.text = item[@"title"];
    NSString *iso = item[@"iso"];
    cell.detailTextLabel.text = iso.length ? iso.uppercaseString : @"auto";
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *item = ChengIOSRegionChoices()[indexPath.row];
    NSString *iso = item[@"iso"];
    NSDictionary *profile = iso.length ? ChengIOSRandomFullProfileInRegion(iso) : ChengIOSRandomFullProfile();
    ChengIOSApplyProfile(profile);
    NSString *text = ChengIOSProfileSummary(profile);
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:item[@"title"]
                                                                   message:text
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Sao chep" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;
        [UIPasteboard generalPasteboard].string = text;
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
