//
//  mruby View Controller Implementation
//

#import "MrubyViewController.h"

#import <libgen.h>
#import "FCFileManager.h"
#import "MrubyUtil.h"
#import "mrb_attr_string.h"
#import "mrb_image.h"
#import "mrb_misc.h"
#import "mruby.h"
#import "mruby/array.h"
#import "mruby/class.h"
#import "mruby/compile.h"
#import "mruby/error.h"
#import "mruby/irep.h"
#import "mruby/string.h"
#import "mruby/variable.h"

MrubyViewController *globalMrubyViewController;

#define INPUT_FIELD_HEIGHT 28

@implementation MrubyViewController {
    NSString* _scriptPath;
    NSString* _runDir;
    mrb_state* _mrb;
    UITextView* _textView;
    BOOL _isCanceled;
    NSMutableArray* _receivePicked;
    QBImagePickerController* _imagePicker;
    UITextField* _inputField;
    BOOL _observed;
    NSMutableAttributedString* _text;
    NSString* _clickedLink;
    BOOL _isBackground;
}

- (id)initWithScriptPath:(NSString*)scriptPath {
    return [self initWithScriptPath:scriptPath runDir:nil];
}

- (id)initWithScriptPath:(NSString*)scriptPath runDir:(NSString*)runDir {
    self = [super init];

    globalMrubyViewController = self;

    _scriptPath = scriptPath;
    _runDir = runDir;
    _mrb = [self initMrb];
    _isCanceled = NO;
    _observed = NO;
    _text = [[NSMutableAttributedString alloc] init];
    _clickedLink = NULL;
    _isBackground = NO;

    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // TextView
    _textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    _textView.editable = NO;
    _textView.dataDetectorTypes = UIDataDetectorTypeLink;
    _textView.font = [MrubyUtil font];
    _textView.text = @"";
	_textView.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
    [self.view addSubview:_textView];
    _textView.delegate = self;

    // ImagePicker
    _imagePicker = [QBImagePickerController new];
    [_imagePicker setDelegate:self];
    _imagePicker.showsNumberOfSelectedAssets = YES;

    // Title
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    button.backgroundColor = [UIColor clearColor];
    [button setTitle:[_scriptPath lastPathComponent] forState:UIControlStateNormal];
    [button setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    button.frame = CGRectMake(0.0, 0.0, 120.0, self.navigationController.navigationBar.frame.size.height);
    self.navigationItem.titleView = button;

    // Input
    _inputField = [[UITextField alloc] initWithFrame:CGRectMake(
            5,
            self.view.frame.size.height - INPUT_FIELD_HEIGHT - 5,
            self.view.frame.size.width - 15,
            INPUT_FIELD_HEIGHT
            )];
    _inputField.borderStyle = UITextBorderStyleRoundedRect;
    _inputField.font = [MrubyUtil font];
    _inputField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _inputField.autocorrectionType = UITextAutocorrectionTypeNo;
    _inputField.returnKeyType = UIReturnKeyDone;
    _inputField.enablesReturnKeyAutomatically = NO;
    _inputField.clearButtonMode = UITextFieldViewModeWhileEditing;
    _inputField.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
    _inputField.placeholder = @"Enter...";
    _inputField.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
    _inputField.delegate = self;
    [self.view addSubview:_inputField];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
        
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];

    [self hiddenInputField:YES];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    NSNotificationCenter *ns = [NSNotificationCenter defaultCenter];

    [ns addObserver:self
           selector:@selector(applicationDidEnterBackground)
               name:UIApplicationDidEnterBackgroundNotification
             object:nil];

    [ns addObserver:self
           selector:@selector(applicationDidBecomeActive)
               name:UIApplicationDidBecomeActiveNotification
             object:nil];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    if (!_observed) {
        [self runMrb];
        _observed = YES;
    }
}

- (void)didMoveToParentViewController:(UIViewController *)parent {
    if (![parent isEqual:self.parentViewController]) {
        _isCanceled = YES;
    }
}

static void
mrb_hook(struct mrb_state* mrb, struct mrb_irep *irep, mrb_code *pc, mrb_value *regs)
{
    if ([globalMrubyViewController isCanceled]) {
        mrb_raise(mrb, E_RUNTIME_ERROR, "Cancel from MrubyViewController");
    }
}

- (mrb_state*)initMrb {
    mrb_state* mrb = mrb_open();

    // Set hook
    mrb->code_fetch_hook = mrb_hook;

    // Bind
    mrb_rubypico_attr_string_init(mrb);
    mrb_rubypico_image_init(mrb);
    mrb_rubypico_misc_init(mrb);

    // Load builtin library
    {
        NSString* path = [FCFileManager pathForMainBundleDirectoryWithPath:@"__builtin__.rb"];
        char* scriptPath = (char *)[path UTF8String];
        FILE *fd = fopen(scriptPath, "r");
        mrb_load_file(mrb, fd);
        fclose(fd);
    }
 
    // Set LOAD_PATH($:)
    {
        mrb_value load_path = mrb_gv_get(mrb, mrb_intern_cstr(mrb, "$:"));
        mrb_ary_push(mrb, load_path, mrb_str_new_cstr(mrb, [[FCFileManager pathForDocumentsDirectory] UTF8String]));
        mrb_ary_push(mrb, load_path, mrb_str_new_cstr(mrb, [[FCFileManager pathForMainBundleDirectory] UTF8String]));
        // mrb_p(mrb, load_path);
    }

    return mrb;
}

- (void)runMrb {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        int arena = mrb_gc_arena_save(_mrb);

        {
            char* scriptPath = (char *)[_scriptPath UTF8String];
            FILE *fd = fopen(scriptPath, "r");

            mrbc_context *cxt = mrbc_context_new(_mrb);

            const char* fileName = [[[[NSString alloc] initWithUTF8String:scriptPath] lastPathComponent] UTF8String];
            mrbc_filename(_mrb, cxt, fileName);
            mrb_gv_set(_mrb, mrb_intern(_mrb, "$0", 2), mrb_str_new_cstr(_mrb, fileName));

            // Change current directory
            if (_runDir) {
                chdir([_runDir UTF8String]);
            } else {
                const char* scriptDir = dirname(scriptPath);

                if (scriptDir == NULL ||
                    strcmp(scriptDir, [[[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:@"sample"] UTF8String]) == 0) {
                    chdir([[FCFileManager pathForDocumentsDirectory] UTF8String]);
                } else {
                    chdir(scriptDir);
                }
            }

            // Run Top Level
            mrb_load_file_cxt(_mrb, fd, cxt);

            // Error handling
            if (_mrb->exc) {
                rubypico_misc_p(_mrb, mrb_obj_value(_mrb->exc));
            }

            mrbc_context_free(_mrb, cxt);

            fclose(fd);
        }

        mrb_gc_arena_restore(_mrb, arena);

        mrb_close(_mrb);
        _mrb = NULL;
    });
}

- (void) appendAttributedString:(NSAttributedString*)attrStr {
    [_text appendAttributedString: attrStr];
    _textView.attributedText = _text;
}

- (void)printstr:(NSString*)str {
    [self appendAttributedString:[[NSAttributedString alloc]
                                     initWithString: str
                                         attributes:@{NSFontAttributeName:[MrubyUtil font]}]];
}

- (void)printAttrString:(NSMutableAttributedString*)str {
    [self appendAttributedString:str];
}

- (void)printimage:(UIImage*)image {
    NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
    attachment.image = image;
    const float MARGIN = 10.0f;
    const float WIDTH = [_textView bounds].size.width - MARGIN;
    if (image.size.width > WIDTH) {
        attachment.bounds = CGRectMake(0.0f, 0.0f, WIDTH, image.size.height / image.size.width * WIDTH);
    }

    [self appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
}

- (BOOL)isCanceled {
    return _isCanceled;
}

- (void)startPopupInput:(NSString*)path {
    _receivePicked = NULL;

    UIAlertView* alert = [[UIAlertView alloc] init];
    alert.title = path;
    [alert addButtonWithTitle:@"Cancel"];
    [alert addButtonWithTitle:@"OK"];
    [alert setAlertViewStyle:UIAlertViewStylePlainTextInput];
    alert.delegate = self;
    alert.cancelButtonIndex = 0;
    [alert show];
}

- (void)startPopupMsg:(NSString*)path {
    _receivePicked = NULL;

    UIAlertView* alert = [[UIAlertView alloc] initWithTitle:@""
                                                    message:path
                                                   delegate:self
                                          cancelButtonTitle:@"OK"
                                          otherButtonTitles:nil];
    [alert show];
}

- (void)alertView:(UIAlertView*)alertView clickedButtonAtIndex:(NSInteger)buttonIndex {
    @synchronized (self) {
        _receivePicked = [[NSMutableArray alloc] initWithCapacity:1];

        if (buttonIndex == alertView.cancelButtonIndex) {
            return;
        }

        NSString* text = [[alertView textFieldAtIndex:0] text];
        [_receivePicked addObject:text];
    }
}

- (NSMutableArray*)receivePicked {
    @synchronized (self) {
        NSMutableArray* array = _receivePicked;
        _receivePicked = NULL;
        return array;
    }
}

- (void)startPickFromLibrary:(int)num {
    _receivePicked = NULL;
    _imagePicker.allowsMultipleSelection = (num > 1) ? YES : NO;
    _imagePicker.maximumNumberOfSelection = num;
    [self presentViewController:_imagePicker animated:YES completion:nil];
}

- (void)qb_imagePickerController:(QBImagePickerController *)picker didFinishPickingAssets:(NSArray *)assets {
    @synchronized (self) {
        _receivePicked = [[NSMutableArray alloc] initWithCapacity:[assets count]];

        PHImageRequestOptions *options = [[PHImageRequestOptions alloc] init];
        options.synchronous = YES;
        options.deliveryMode = PHImageRequestOptionsDeliveryModeHighQualityFormat;
        options.resizeMode = PHImageRequestOptionsResizeModeExact;

        for (PHAsset* asset in assets) {
            [[PHImageManager defaultManager] requestImageForAsset:asset
                                                    targetSize:PHImageManagerMaximumSize
                                                    contentMode:PHImageContentModeAspectFit
                                                        options:options
                                                    resultHandler:^(UIImage *result, NSDictionary *info) {
                    if (result) {
                        [_receivePicked addObject:result];
                    }
                }];
        }

        [self dismissViewControllerAnimated:YES completion:NULL];
    }
}

- (void)qb_imagePickerControllerDidCancel:(QBImagePickerController *)picker {
    @synchronized (self) {
        [self dismissViewControllerAnimated:YES completion:NULL];
    }
}

- (CGRect)onscreenFrame
{
	return [UIScreen mainScreen].applicationFrame;
}

- (void)keyboardWillShow:(NSNotification *)notification {	
	CGRect frame = [[notification.userInfo valueForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
	CGFloat duration = [[notification.userInfo valueForKey:UIKeyboardAnimationDurationUserInfoKey] floatValue];
	UIViewAnimationCurve curve = [[notification.userInfo valueForKey:UIKeyboardAnimationCurveUserInfoKey] intValue];
	
	[UIView beginAnimations:nil context:NULL];
	[UIView setAnimationBeginsFromCurrentState:YES];
	[UIView setAnimationDuration:duration];
	[UIView setAnimationCurve:curve];
	
	CGRect bounds = [self onscreenFrame];
	switch ([UIApplication sharedApplication].statusBarOrientation)
    {
		case UIInterfaceOrientationPortrait:
        case UIInterfaceOrientationUnknown:
			bounds.size.height -= frame.size.height;
			break;
		case UIInterfaceOrientationPortraitUpsideDown:
			bounds.origin.y += frame.size.height;
			bounds.size.height -= frame.size.height;
			break;
		case UIInterfaceOrientationLandscapeLeft:
			bounds.size.width -= frame.size.width;
			break;
		case UIInterfaceOrientationLandscapeRight:
			bounds.origin.x += frame.size.width;
			bounds.size.width -= frame.size.width;
			break;
	}
	self.view.frame = bounds;
	
	[UIView commitAnimations];
}

- (void)keyboardWillHide:(NSNotification *)notification {
	CGFloat duration = [[notification.userInfo valueForKey:UIKeyboardAnimationDurationUserInfoKey] floatValue];
	UIViewAnimationCurve curve = [[notification.userInfo valueForKey:UIKeyboardAnimationCurveUserInfoKey] intValue];
	
	[UIView beginAnimations:nil context:NULL];
	[UIView setAnimationBeginsFromCurrentState:YES];
	[UIView setAnimationDuration:duration];
	[UIView setAnimationCurve:curve];
	
	self.view.frame = [self onscreenFrame];	
	
	[UIView commitAnimations];
}

- (void)hiddenInputField:(BOOL)hidden {
    if (hidden) {
        _textView.frame = self.view.bounds;
    } else {
        CGRect frame = self.view.bounds;
        frame.size.height -= INPUT_FIELD_HEIGHT + 10;
        _textView.frame = frame;
    }

    _inputField.hidden = hidden;
}

- (void)startInput {
    _receivePicked = NULL;
    [self hiddenInputField:NO];
    [_inputField becomeFirstResponder];
}

- (void)clear {
    [[_text mutableString] setString:@""];
    _textView.attributedText = _text;
}

- (void)textFieldDidEndEditing:(UITextField *)textField {
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    @synchronized (self) {
        _receivePicked = [[NSMutableArray alloc] initWithCapacity:1];
        [_receivePicked addObject:textField.text];

        textField.text = @"";

        [self hiddenInputField:YES];
        [textField resignFirstResponder];
    }

    return YES;
}

- (BOOL)textFieldShouldClear:(UITextField *)textField {
    return YES;
}

- (NSString*)getClickedLink {
    @synchronized (self) {
        NSString *str = _clickedLink;
        _clickedLink = NULL;
        return str;
    }
}

- (BOOL)textView:(UITextView *)textView shouldInteractWithURL:(NSURL *)URL inRange:(NSRange)characterRange {
    @synchronized (self) {
        _clickedLink = URL.absoluteString;
    }
    return YES;
}

- (BOOL)isBackground
{
    return _isBackground;
}

- (void)setBackground
{
    _isBackground = YES;
}

- (void)applicationDidEnterBackground
{
    _isBackground = YES;
}

- (void)applicationDidBecomeActive
{
    _isBackground = NO;
}

@end
