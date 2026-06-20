#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>

NS_ASSUME_NONNULL_BEGIN

BOOL DDAXTrusted(void);
void DDAXRequestTrust(void);
BOOL DDAXCopyFrame(AXUIElementRef window, CGRect *outFrame);
void DDAXSetFrame(AXUIElementRef window, CGRect frame);
void DDAXRaise(AXUIElementRef window);
void DDAXActivateApp(pid_t pid);

@interface DDManagedWindow : NSObject
@property (nonatomic, readonly) AXUIElementRef window;
@property (nonatomic, readonly) pid_t pid;
@property (nonatomic, readonly) CGRect frame;
@end

NSArray<DDManagedWindow *> *DDAXManageableWindowsOnScreen(CGRect visibleFrame);

NS_ASSUME_NONNULL_END
