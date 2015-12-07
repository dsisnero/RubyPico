#import "BindPopup.hpp"
#import "BindImage.hpp"

#import "mruby.h"
#import "mruby/string.h"
#import <UIKit/UIKit.h>

namespace pictruby {

namespace {
mrb_value start_popup_input(mrb_state *mrb, mrb_value self)
{
    mrb_value str;
    mrb_get_args(mrb, "S", &str);

    const char* path = mrb_string_value_ptr(mrb, str);
    NSString *npath = [[NSString alloc] initWithUTF8String:path];

    [globalScriptController startPopupInput:npath];

    return mrb_nil_value();
}

mrb_value start_popup_msg(mrb_state *mrb, mrb_value self)
{
    mrb_value str;
    mrb_get_args(mrb, "S", &str);

    const char* path = mrb_string_value_ptr(mrb, str);
    NSString *npath = [[NSString alloc] initWithUTF8String:path];

    [globalScriptController startPopupMsg:npath];

    return mrb_nil_value();
}

mrb_value receive_picked(mrb_state *mrb, mrb_value self)
{
    NSMutableArray* nsarray = [globalScriptController receivePicked];

    if (nsarray == NULL) {
        return mrb_nil_value();
    }

    if (nsarray.count > 0) {
        mrb_value str = mrb_str_new_cstr(mrb, [nsarray[0] UTF8String]);
        return str;
    } else {
        mrb_value str = mrb_str_new_cstr(mrb, "");
        return str;
    }
}

mrb_value get(mrb_state *mrb, mrb_value self)
{
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    NSString *string = [pasteboard valueForPasteboardType:@"public.text"];

    return mrb_str_new_cstr(mrb, [string UTF8String]);
}

}

//----------------------------------------------------------
void BindPopup::Bind(mrb_state* mrb)
{
    {
        struct RClass *cc = mrb_define_class(mrb, "Popup", mrb->object_class);

        mrb_define_class_method(mrb , cc, "start_popup_input", start_popup_input, MRB_ARGS_REQ(1));
        mrb_define_class_method(mrb , cc, "start_popup_msg"  , start_popup_msg  , MRB_ARGS_REQ(1));
        mrb_define_class_method(mrb , cc, "receive_picked"   , receive_picked   , MRB_ARGS_NONE());
    }

    {
        struct RClass *cc = mrb_define_class(mrb, "Clipboard", mrb->object_class);

        mrb_define_class_method(mrb , cc, "get", get, MRB_ARGS_NONE());
    }
}

}
