#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// NSTextCheckingController can send non-string values despite its annotation dictionary's declared value type.
NS_SWIFT_UI_ACTOR
@interface TextCheckingAnnotationClient : NSObject
- (void)setAnnotations:(NSDictionary<NSAttributedStringKey, NSString *> *)annotations range:(NSRange)range;
- (void)addAnnotations:(NSDictionary<NSAttributedStringKey, NSString *> *)annotations range:(NSRange)range;
- (void)receiveAnnotations:(NSDictionary<NSAttributedStringKey, id> *)annotations range:(NSRange)range replacing:(BOOL)replacing;
@end

NS_ASSUME_NONNULL_END
