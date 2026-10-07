#!/usr/bin/env python3
"""Builds en.lproj/Localizable.strings and ru.lproj/Localizable.strings.

Source of truth is the original langpack XML from the EyeLeo project, so the wording stays
identical. Keys not present there are added here with a comment saying so.

Transformations applied to the imported strings:
  {n} -> a real newline (the original app did this substitution at load time)
  %s  -> %@     (printf-style placeholders do not work with NSString formatting)
"""

import os
import xml.etree.ElementTree as ET

SRC = "/Users/Def/Projects/eyeleoapp-master/bin/Langpacks"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")


def load(path):
    out = {}
    for e in ET.parse(path).getroot().iter("string"):
        out[e.get("id")] = (e.get("text") or "").strip()
    return out


def fix(text):
    return text.replace("{n}", "\n").replace("%s", "%@")


# Keys dropped from the original build: they pitch donations, Patreon and feedback forms,
# which do not belong in a private copy.
DROP = {
    "information_info_2", "information_info_3", "information_give_feedback_button",
    "information_make_donation_button",
}

# --- Russian fills for keys the original ru pack never had (it ships lines 1-3 only) ---------
RU_EXERCISE_VERB = {
    1: "Повращайте глазами.",
    2: "Двигайте глазами вверх и вниз.",
    3: "Двигайте глазами влево и вправо.",
    4: "Закройте глаза на несколько секунд.",
    5: "Моргайте.",
    6: "Посмотрите вдаль за окно.",
    7: "Потянитесь.",
    # Added in the port. Ids 8, 9 and 10 do not exist in the original langpack, so all five phrasings
    # are written out below rather than derived from it. Ids 1..7 are untouched.
    8: "Закройте глаза полностью и мягко, десять раз.",
    9: "Поднимите и опустите плечи.",
    10: "Закройте глаза ладонями.",
}

# Full phrasings for the three exercises added in the port. The four templated lines the generator
# derives from RU_EXERCISE_VERB ("Время для перерыва.", "Короткий перерыв!") read acceptably for
# these as well, so only lines 1-3 need writing. Line 3 is a different phrasing on purpose, so the
# five are not five renderings of one sentence.
RU_PORT_ADDED = {
    8: [
        "Короткий перерыв!\nЗакройте глаза полностью и мягко, десять раз.",
        "Время для перерыва!\nЗакройте глаза полностью и мягко, десять раз.",
        "Перерыв!\nЗакройте глаза полностью и мягко, десять раз.",
        "Время для перерыва.\nЗакройте глаза полностью и мягко, десять раз.",
        "Короткий перерыв!\nЗакройте глаза полностью и мягко, десять раз.",
    ],
    9: [
        "Короткий перерыв!\nПоднимите и опустите плечи.",
        "Время для перерыва!\nПоднимите и опустите плечи.",
        "Перерыв!\nПоднимите и опустите плечи.",
        "Время для перерыва.\nПоднимите и опустите плечи.",
        "Короткий перерыв!\nПоднимите и опустите плечи.",
    ],
    10: [
        "Сделайте мини-перерыв\nи закройте глаза ладонями.",
        "Время для перерыва.\nЗакройте глаза ладонями.",
        "Короткий перерыв!\nПриложите ладони к глазам.",
        "Время для перерыва!\nНакройте глаза ладонями.",
        "Короткий перерыв!\nДайте глазам отдых в темноте ладоней.",
    ],
}
RU_EXTRA = {}
for ex, verb in RU_EXERCISE_VERB.items():
    RU_EXTRA[f"mini_pause_text_{ex}_4"] = f"Время для перерыва.\n{verb}"
    RU_EXTRA[f"mini_pause_text_{ex}_5"] = f"Короткий перерыв!\n{verb}"
for ex, lines in RU_PORT_ADDED.items():
    for idx, text in enumerate(lines, start=1):
        RU_EXTRA[f"mini_pause_text_{ex}_{idx}"] = text

# The same three exercises in English. Ids 8, 9 and 10 are not in the original langpack either, so
# these five phrasings each are the original English wording of the ports, kept alongside RU_PORT_ADDED
# rather than derived from it: the Russian is a translation of these, not the other way round.
EN_PORT_ADDED = {
    8: [
        "Take a short break!\nClose your eyes fully and gently, ten times.",
        "Time for a short break!\nClose your eyes fully and gently, ten times.",
        "Break!\nClose your eyes fully and gently, ten times.",
        "Time for a break!\nClose your eyes fully and gently, ten times.",
        "Short break!\nClose your eyes fully and gently, ten times.",
    ],
    9: [
        "Take a short break!\nRaise and lower your shoulders.",
        "Time for a short break!\nRaise and lower your shoulders.",
        "Break!\nRaise and lower your shoulders.",
        "Time for a break!\nRaise and lower your shoulders.",
        "Short break!\nRaise and lower your shoulders.",
    ],
    10: [
        "Take a short break!\nCover your eyes with your palms.",
        "Take a break!\nCover your eyes with your palms.",
        "Time for a short break!\nCup your hands over your eyes.",
        "Time for a break!\nCover your eyes with your palms.",
        "Short break!\nRest your eyes in the dark of your hands.",
    ],
}
# Filled into EXTRA["en"] after EXTRA is defined, below.

# Milestone lines. The original spends four of its eight slots on donation and update
# prompts; those are replaced with neutral reminders.
NEUTRAL = {
    "en": {
        "mini_pause_text_donate": "Blinking keeps the eyes moist.",
        "mini_pause_text_check_eyeleo": "Sit a little further from the screen.",
        "mini_pause_text_tell_friend": "Twenty twenty: every 20 minutes, look 20 feet away.",
        # Exercises 8 and 9, added in the port. Ids 1..7 keep the original wording untouched.
        "mini_pause_text_8_1": "Take a short break!\nClose your eyes fully and gently, ten times.",
        "mini_pause_text_8_2": "Time for a short break!\nClose your eyes fully and gently, ten times.",
        "mini_pause_text_8_3": "Break!\nClose your eyes fully and gently, ten times.",
        "mini_pause_text_8_4": "Time for a break!\nClose your eyes fully and gently, ten times.",
        "mini_pause_text_8_5": "Short break!\nClose your eyes fully and gently, ten times.",
        "mini_pause_text_9_1": "Take a short break!\nRaise and lower your shoulders.",
        "mini_pause_text_9_2": "Time for a short break!\nRaise and lower your shoulders.",
        "mini_pause_text_9_3": "Break!\nRaise and lower your shoulders.",
        "mini_pause_text_9_4": "Time for a break!\nRaise and lower your shoulders.",
        "mini_pause_text_9_5": "Short break!\nRaise and lower your shoulders.",
        # Hydration reminder and its settings. Added in the port.
        "water_reminder_label": "Drink some water",
        "settings_water_group_label": "Water",
        "settings_water_reminder_label": "Remind me to drink",
        "settings_water_interval_label": "Every",
        "settings_water_volume_label": "Portion",
        "settings_water_interval_value_1": "15 minutes",
        "settings_water_interval_value_2": "20 minutes",
        "settings_water_interval_value_3": "25 minutes",
        "settings_water_interval_value_4": "30 minutes",
        "settings_water_interval_value_5": "45 minutes",
        "settings_water_interval_value_6": "60 minutes",
        "settings_water_interval_value_7": "90 minutes",
        "settings_water_interval_value_8": "120 minutes",
        "settings_water_volume_value_1": "50 ml",
        "settings_water_volume_value_2": "100 ml",
        "settings_water_volume_value_3": "150 ml",
        "settings_water_volume_value_4": "200 ml",
        "settings_water_volume_value_5": "250 ml",
    },
    "ru": {
        "mini_pause_text_donate": "Моргание увлажняет глаза.",
        "mini_pause_text_check_eyeleo": "Отсядьте чуть дальше от экрана.",
        "mini_pause_text_tell_friend": "Правило 20-20-20: каждые 20 минут смотрите вдаль.",
        "water_reminder_label": "Попей воды",
        "settings_water_group_label": "Вода",
        "settings_water_reminder_label": "Напоминать попить",
        "settings_water_interval_label": "Каждые",
        "settings_water_volume_label": "Порция",
        "settings_water_interval_value_1": "15 минут",
        "settings_water_interval_value_2": "20 минут",
        "settings_water_interval_value_3": "25 минут",
        "settings_water_interval_value_4": "30 минут",
        "settings_water_interval_value_5": "45 минут",
        "settings_water_interval_value_6": "60 минут",
        "settings_water_interval_value_7": "90 минут",
        "settings_water_interval_value_8": "120 минут",
        "settings_water_volume_value_1": "50 мл",
        "settings_water_volume_value_2": "100 мл",
        "settings_water_volume_value_3": "150 мл",
        "settings_water_volume_value_4": "200 мл",
        "settings_water_volume_value_5": "250 мл",
    },
}

EXTRA = {
    "en": {
        "status.error": "EyeLeo is resting",
        "tb_menu_open_at_login": "Open at login",
        "settings_start_at_login": "Open at login",
        "settings_start_at_login_tooltip": "Let macOS start EyeLeo when you log in",
        "information_stats": "Statistics",
        "information_stats_fmt": "Long breaks: %@\nShort breaks: %@\nSkipped long breaks: %@\nPostponed: %@\nRefused: %@",
        "time.too_many_hours": "more than an hour",
        "unit.minute.one": "minute",
        "unit.minute.few": "minutes",
        "unit.minute.many": "minutes",
        "unit.second.one": "second",
        "unit.second.few": "seconds",
        "unit.second.many": "seconds",
        "unit.hour.one": "hour",
        "unit.hour.few": "hours",
        "unit.hour.many": "hours",
        # The tea submenu. The steeps themselves are timed from tea.conf, not from strings.
        "tb_menu_pour": "Pour",
        "tb_menu_new_tea": "New tea",
    },
    "ru": {
        "status.error": "EyeLeo отдыхает",
        "tb_menu_open_at_login": "Запускать при входе",
        # The tea submenu. The steeps themselves are timed from tea.conf, not from strings.
        "tb_menu_pour": "Пролив",
        "tb_menu_new_tea": "Новый чай",
        "settings_start_at_login": "Запускать при входе",
        "settings_start_at_login_tooltip": "Разрешить macOS запускать EyeLeo при входе в систему",
        "information_stats": "Статистика",
        "information_stats_fmt": "Больших перерывов: %@\nКоротких перерывов: %@\nПропущено больших: %@\nОтложено: %@\nОтказов: %@",
        "time.too_many_hours": "больше часа",
        "unit.minute.one": "минута",
        "unit.minute.few": "минуты",
        "unit.minute.many": "минут",
        "unit.second.one": "секунда",
        "unit.second.few": "секунды",
        "unit.second.many": "секунд",
        "unit.hour.one": "час",
        "unit.hour.few": "часа",
        "unit.hour.many": "часов",
    },
}

# The five dropdown lists of the settings window, in the original's order.
LIST_KEYS = (
    [f"settings_big_pause_value_1_{i}" for i in range(1, 11)]
    + [f"settings_big_pause_value_2_{i}" for i in range(1, 9)]
    + [f"settings_big_pause_warning_value_{i}" for i in range(1, 5)]
    + [f"settings_mini_pause_value_{i}" for i in range(1, 7)]
    + [f"settings_mini_pause_duration_value_{i}" for i in range(1, 4)]
)

# Everything the app looks up.
BASE_KEYS = (
    [k for k in [
        "tb_menu_quit", "tb_menu_quit_tip", "tb_menu_pause_monitoring",
        "tb_menu_pause_monitoring_1", "tb_menu_pause_monitoring_2", "tb_menu_pause_monitoring_tip",
        "tb_menu_resume_monitoring", "tb_menu_settings", "tb_menu_take_break_now",
        "tb_popup_default", "tb_popup_active_1", "tb_popup_paused",
        "tb_notification_first_launch", "tb_notification_start_after_pause",
        "tb_notification_long_break", "tb_notification_auto_relax_ended",
        "settings_title", "settings_settings_tab", "settings_information_tab",
        "settings_general_panel_label",
        "settings_big_pause_label_1", "settings_big_pause_label_2", "settings_big_pause_tooltip",
        "settings_big_pause_warning_label", "settings_big_pause_warning_tooltip",
        "settings_mini_pause_label", "settings_mini_pause_tooltip",
        "settings_mini_pause_fullscreen", "settings_mini_pause_fullscreen_tooltip",
        "settings_enable_sounds_label",
        "settings_enable_strict_mode_label", "settings_enable_strict_mode_tooltip",
        "settings_have_window_nearby", "settings_have_window_nearby_tooltip",
        "settings_can_close_notifications_label", "settings_can_close_notifications_tooltip",
        "settings_can_enable_inactivity_tracking", "settings_can_enable_inactivity_tracking_tooltip",
        "settings_show_notifications", "settings_show_notifications_tooltip",
        "settings_save_and_close_button", "settings_try_short_break_button", "settings_try_long_break_button",
        "information_info_1", "information_author", "information_license",
        "mini_pause_text_settings", "mini_pause_text_posture",
        "before_pause_text", "before_pause_refuse_button", "before_pause_postpone_button",
        "before_pause_accept_button",
        "waiting_text",
        "big_pause_text_1", "big_pause_text_2", "big_pause_text_3",
        "big_pause_time_left_text", "big_pause_skip_button",
        "notification_wnd_label",
    ]]
    + LIST_KEYS
    # Exercises 1..7 are the original's. 8, 9 and 10 were added in the port and carry no langpack
    # entry, so their phrasings come from EXTRA/RU_EXTRA below; the range has to reach them or the
    # generator writes a file that silently drops all three.
    + [f"mini_pause_text_{e}_{i}" for e in range(1, 11) for i in range(1, 6)]
)

# ORDER is built from BASE_KEYS and the extra dictionaries, and both must exist before it is.
for ex, lines in EN_PORT_ADDED.items():
    for idx, text in enumerate(lines, start=1):
        EXTRA["en"][f"mini_pause_text_{ex}_{idx}"] = text

ORDER = BASE_KEYS + sorted(EXTRA["en"]) + sorted(set(NEUTRAL["en"]))


def build(lang, src, extra_fill):
    strings = {}
    for key in ORDER:
        if key in DROP:
            continue
        if key in extra_fill:
            strings[key] = extra_fill[key]
        elif key in NEUTRAL[lang]:
            strings[key] = NEUTRAL[lang][key]
        elif key in EXTRA[lang]:
            strings[key] = EXTRA[lang][key]
        elif key in src:
            strings[key] = fix(src[key])
        else:
            raise SystemExit(f"[{lang}] no source for key {key}")

    path = os.path.join(OUT, f"{lang}.lproj", "Localizable.strings")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(f"/* Generated by tools/gen_strings.py from {os.path.basename(SRC)}/langpack.{lang}.xml.\n")
        f.write("   Do not edit by hand. {n} was expanded, %s became %@. */\n\n")
        for key in strings:
            value = strings[key].replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
            f.write(f'"{key}" = "{value}";\n')
    return path, len(strings)


if __name__ == "__main__":
    en = load(os.path.join(SRC, "langpack.en.xml"))
    ru = load(os.path.join(SRC, "langpack.ru.xml"))
    ru.update(RU_EXTRA)
    for lang, src in (("en", en), ("ru", ru)):
        p, n = build(lang, src, {})
        print(f"{p} ({n} keys)")