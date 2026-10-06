// Verifies the localization of a built EyeLeo.app: that both .lproj directories are packaged,
// that every key the app asks for resolves, and that the plural rules produce sane output.
//
// Reading a bundle's strings needs no permission, so this is a real check rather than a guess.
//
//   clang -O2 -fobjc-arc -I src -o build/checkstrings tools/check_strings.m \
//       src/ebtext.m -framework Foundation
//   ./build/checkstrings build/EyeLeo.app en
//   ./build/checkstrings build/EyeLeo.app ru

#import <Foundation/Foundation.h>

#import "ebtext.h"

void EBSetRussianForTesting(BOOL force);
void EBSetStringsBundle(NSBundle *_Nullable bundle);

// Every key the code looks up, so a missing one shows up here instead of as a raw key on screen.
static NSArray<NSString *> *AllKeys(void) {
    NSMutableArray *keys = [NSMutableArray array];
    for (NSString *k in @[
        @"tb_menu_quit", @"tb_menu_quit_tip", @"tb_menu_pause_monitoring", @"tb_menu_pause_monitoring_1",
        @"tb_menu_pause_monitoring_2", @"tb_menu_pause_monitoring_tip", @"tb_menu_resume_monitoring",
        @"tb_menu_settings", @"tb_menu_take_break_now", @"tb_menu_open_at_login", @"tb_popup_default",
        @"tb_popup_active_1", @"tb_popup_paused", @"tb_notification_first_launch",
        @"tb_notification_start_after_pause", @"tb_notification_long_break",
        @"tb_notification_auto_relax_ended", @"settings_title", @"settings_settings_tab",
        @"settings_information_tab", @"settings_general_panel_label", @"settings_big_pause_label_1",
        @"settings_big_pause_label_2", @"settings_big_pause_tooltip", @"settings_big_pause_warning_label",
        @"settings_big_pause_warning_tooltip", @"settings_mini_pause_label", @"settings_mini_pause_tooltip",
        @"settings_mini_pause_fullscreen", @"settings_mini_pause_fullscreen_tooltip",
        @"settings_enable_sounds_label", @"settings_enable_strict_mode_label",
        @"settings_enable_strict_mode_tooltip", @"settings_have_window_nearby",
        @"settings_have_window_nearby_tooltip", @"settings_can_close_notifications_label",
        @"settings_can_close_notifications_tooltip", @"settings_can_enable_inactivity_tracking",
        @"settings_can_enable_inactivity_tracking_tooltip", @"settings_show_notifications",
        @"settings_show_notifications_tooltip", @"settings_save_and_close_button",
        @"settings_try_short_break_button", @"settings_try_long_break_button",
        @"settings_start_at_login", @"settings_start_at_login_tooltip",
        @"information_info_1",
        @"information_author", @"information_stats", @"information_stats_fmt", @"status.error",
        @"time.too_many_hours", @"before_pause_text", @"before_pause_refuse_button",
        @"before_pause_postpone_button", @"before_pause_accept_button", @"waiting_text",
        @"big_pause_text_1", @"big_pause_text_2", @"big_pause_text_3", @"big_pause_time_left_text",
        @"big_pause_skip_button", @"notification_wnd_label", @"mini_pause_text_settings",
        @"mini_pause_text_posture", @"mini_pause_text_donate", @"mini_pause_text_tell_friend",
        @"mini_pause_text_check_eyeleo",
        @"unit.minute.one", @"unit.minute.few", @"unit.minute.many", @"unit.second.one",
        @"unit.second.few", @"unit.second.many", @"unit.hour.one", @"unit.hour.few", @"unit.hour.many",
    ]) {
        [keys addObject:k];
    }
    for (int e = 1; e <= 7; e++)
        for (int i = 1; i <= 5; i++)
            [keys addObject:[NSString stringWithFormat:@"mini_pause_text_%d_%d", e, i]];
    for (int i = 1; i <= 10; i++)
        [keys addObject:[NSString stringWithFormat:@"settings_big_pause_value_1_%d", i]];
    for (int i = 1; i <= 8; i++)
        [keys addObject:[NSString stringWithFormat:@"settings_big_pause_value_2_%d", i]];
    for (int i = 1; i <= 4; i++)
        [keys addObject:[NSString stringWithFormat:@"settings_big_pause_warning_value_%d", i]];
    for (int i = 1; i <= 6; i++)
        [keys addObject:[NSString stringWithFormat:@"settings_mini_pause_value_%d", i]];
    for (int i = 1; i <= 3; i++)
        [keys addObject:[NSString stringWithFormat:@"settings_mini_pause_duration_value_%d", i]];
    return keys;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: checkstrings <path/to/App.bundle> [en|ru]\n");
            return 2;
        }
        NSBundle *bundle = [NSBundle bundleWithPath:@(argv[1])];
        if (!bundle) {
            fprintf(stderr, "no bundle at %s\n", argv[1]);
            return 2;
        }

        NSString *lang = argc > 2 ? @(argv[2]) : @"en";
        EBSetRussianForTesting([lang isEqualToString:@"ru"]);

        // Read the requested .lproj explicitly rather than whatever the process locale picks,
        // so this checker can inspect both languages in one run.
        NSString *lproj = [bundle pathForResource:lang ofType:@"lproj"];
        NSBundle *langBundle = lproj ? [NSBundle bundleWithPath:lproj] : nil;
        if (!langBundle) {
            fprintf(stderr, "no %s.lproj inside the bundle\n", lang.UTF8String);
            return 2;
        }
        EBSetStringsBundle(langBundle);

        printf("bundle: %s\n", bundle.bundlePath.UTF8String);
        printf("localizations found: %s\n", [[bundle.localizations componentsJoinedByString:@", "] UTF8String]);

        int missing = 0;
        for (NSString *key in AllKeys()) {
            NSString *value = [bundle localizedStringForKey:key value:nil table:@"Localizable"];
            if (!value || value.length == 0 || [value isEqualToString:key]) {
                printf("  MISSING  %s\n", key.UTF8String);
                missing++;
            }
        }
        printf("keys checked: %lu, missing: %d\n", (unsigned long)AllKeys().count, missing);

        printf("\nremaining-time rendering in '%s':\n", lang.UTF8String);
        long samples[] = { 5000, 45000, 90000, 200000, 350000, 3 * 3600000L + 125000 };
        for (unsigned i = 0; i < sizeof(samples) / sizeof(samples[0]); i++) {
            printf("  %9ld ms -> %-22s  |  forced: %s\n", samples[i],
                   EBTimeLeftText(samples[i], [lang isEqualToString:@"ru"], NO).UTF8String,
                   EBTimeLeftText(samples[i], [lang isEqualToString:@"ru"], YES).UTF8String);
        }

        printf("\nplural forms:\n");
        long counts[] = { 1, 2, 5, 11, 21, 22, 25, 101, 111 };
        for (unsigned i = 0; i < sizeof(counts) / sizeof(counts[0]); i++)
            printf("  %3ld min -> %-14s | %3ld sec -> %s\n", counts[i],
                   EBPluralWord(counts[i], @"minute", [lang isEqualToString:@"ru"]).UTF8String, counts[i],
                   EBPluralWord(counts[i], @"second", [lang isEqualToString:@"ru"]).UTF8String);

        return missing == 0 ? 0 : 1;
    }
}