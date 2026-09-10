#import "SRSwitchTableCell.h"
#import <UIKit/UIKit.h>

@implementation SRSwitchTableCell
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:identifier specifier:specifier];
    if (self) {
        UISwitch *control = (UISwitch *)self.control;
        if ([control isKindOfClass:[UISwitch class]]) {
            if (@available(iOS 13.0, *)) {
                control.onTintColor = [UIColor systemGreenColor];
            } else {
                control.onTintColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
            }
        }
    }
    return self;
}
@end
