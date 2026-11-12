#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import "../Common/Common.h"

@interface RDRootVC : PSListController
@end

@implementation RDRootVC

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UIImage *icon = [UIImage imageNamed:@"SettingsIcon"
        inBundle:[NSBundle bundleForClass:[self class]]
        compatibleWithTraitCollection:nil];
    if (icon) {
        UIImageView *image = [[UIImageView alloc] initWithImage:icon];
        image.contentMode = UIViewContentModeScaleAspectFit;
        image.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [image.widthAnchor constraintEqualToConstant:24],
            [image.heightAnchor constraintEqualToConstant:24]
        ]];
        UILabel *title = [UILabel new];
        title.text = @"Reynard Default";
        title.font = [UIFont boldSystemFontOfSize:17];
        UIStackView *header = [[UIStackView alloc]
            initWithArrangedSubviews:@[image, title]];
        header.axis = UILayoutConstraintAxisHorizontal;
        header.alignment = UIStackViewAlignmentCenter;
        header.spacing = 8;
        self.navigationItem.titleView = header;
    }
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
    [prefs setObject:value forKey:specifier.properties[@"key"]];
    [prefs synchronize];
    [super setPreferenceValue:value specifier:specifier];
}

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSUserDefaults *prefs = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName];
    id value = [prefs objectForKey:specifier.properties[@"key"]];
    if (!value) {
        return specifier.properties[@"default"];
    }
    return value;
}

- (void)openGitHub {
    [[UIApplication sharedApplication] openURL:[NSURL URLWithString:@"https://github.com/551UK/Reynards-Default-iOS16."] options:@{} completionHandler:nil];
}

@end
