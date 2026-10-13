#import "TextCheckingBridge.h"

@implementation TextCheckingAnnotationClient
- (void)setAnnotations:(NSDictionary<NSAttributedStringKey, NSString *> *)annotations range:(NSRange)range {
    [self receiveAnnotations:annotations range:range replacing:YES];
}
- (void)addAnnotations:(NSDictionary<NSAttributedStringKey, NSString *> *)annotations range:(NSRange)range {
    [self receiveAnnotations:annotations range:range replacing:NO];
}
- (void)receiveAnnotations:(NSDictionary<NSAttributedStringKey, id> *)annotations range:(NSRange)range replacing:(BOOL)replacing {}
@end
