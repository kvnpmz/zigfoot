# E1 shim audit

Base: `9f4f1def`. Audit date: 2026-11-25.

## Scope and result

The checkout has 13 `*-shim.c` files, not 11. The files contain 390 functions and 3,417 lines.

- Class a: 259 functions. Keep them.
- Class b: 57 functions. One dead mirror adapter was deleted.
- Class c: 74 functions. Keep them and port the logic later. Their C bodies total 591 lines.
- Applied deletion: `grid-shim.c`, 37 lines.
- Result: 12 files, 389 functions, and 3,380 lines.

Class b means that the C body only uses a struct mirror pinned by the ABI probe. The action is deletion in principle. Fifty-six functions are still called by module Zig code. This task forbids module logic edits, so those functions are on hold. Agent A can replace each extern call with direct field access and then delete the function. The held function spans total 175 lines, before blank-line cleanup.

Class c means that logic leaked into the shim. The action is a later port. The table gives the C body line count for each candidate.

## Line counts

| File | Before | After | Change |
|---|---:|---:|---:|
| `csi-shim.c` | 152 | 152 | +0 |
| `dcs-shim.c` | 36 | 36 | +0 |
| `grid-shim.c` | 37 | 0 | -37 |
| `main-shim.c` | 17 | 17 | +0 |
| `notify-shim.c` | 250 | 250 | +0 |
| `osc-shim.c` | 156 | 156 | +0 |
| `shm-shim.c` | 208 | 208 | +0 |
| `sixel-shim.c` | 157 | 157 | +0 |
| `terminal-shim.c` | 1974 | 1974 | +0 |
| `vt-shim.c` | 55 | 55 | +0 |
| `wayland-shim.c` | 316 | 316 | +0 |
| `xmalloc-shim.c` | 31 | 31 | +0 |
| `xsnprintf-shim.c` | 28 | 28 | +0 |
| **Total** | **3417** | **3380** | **-37** |

## Deletion reason

`grid_resize_and_reflow()` only read the ABI-probed `Terminal.composed` field and called the Zig grid function. `grid.zig` now exports that operation. The file had no callers and was not in the Meson build, so the mirror adapter and its file were deleted.

## Function table

Action `HOLD` is a class b deletion that needs a module-owner call-site edit. Action `PORT` is class c. The number is the C body line count.

| File | Function | Class | Action |
|---|---|---|---|
| `csi-shim.c` | `csi_xtsave_get()` | c | PORT (5 body lines) |
| `csi-shim.c` | `csi_xtsave_set()` | c | PORT (7 body lines) |
| `csi-shim.c` | `csi_size_notifications()` | b | HOLD for module owner |
| `csi-shim.c` | `csi_grapheme_shaping()` | b | HOLD for module owner |
| `csi-shim.c` | `csi_set_grapheme_shaping()` | b | HOLD for module owner |
| `csi-shim.c` | `csi_modify_other_keys_2()` | b | HOLD for module owner |
| `csi-shim.c` | `csi_set_modify_other_keys_2()` | b | HOLD for module owner |
| `csi-shim.c` | `csi_conf_cursor_blink_enabled()` | b | HOLD for module owner |
| `csi-shim.c` | `csi_conf_cursor_style()` | b | HOLD for module owner |
| `csi-shim.c` | `csi_conf_security_osc52()` | b | HOLD for module owner |
| `csi-shim.c` | `csi_conf_grapheme_width_method()` | b | HOLD for module owner |
| `csi-shim.c` | `csi_conf_tweak_sixel()` | b | HOLD for module owner |
| `csi-shim.c` | `csi_set_url_ime_reenable_after_url_mode()` | b | HOLD for module owner |
| `csi-shim.c` | `csi_c32width()` | a | KEEP |
| `csi-shim.c` | `csi_window_first_output_px_width()` | c | PORT (7 body lines) |
| `csi-shim.c` | `csi_window_first_output_px_height()` | c | PORT (7 body lines) |
| `csi-shim.c` | `csi_window_on_outputs_count()` | c | PORT (4 body lines) |
| `csi-shim.c` | `csi_window_title_stack_len()` | c | PORT (3 body lines) |
| `csi-shim.c` | `csi_window_title_stack_push()` | c | PORT (3 body lines) |
| `csi-shim.c` | `csi_window_title_stack_pop()` | c | PORT (4 body lines) |
| `csi-shim.c` | `csi_foot_version_major()` | a | KEEP |
| `csi-shim.c` | `csi_foot_version_minor()` | a | KEEP |
| `csi-shim.c` | `csi_foot_version_patch()` | a | KEEP |
| `csi-shim.c` | `csi_foot_version_extra()` | a | KEEP |
| `dcs-shim.c` | `dcs_terminfo_capabilities()` | a | KEEP |
| `dcs-shim.c` | `dcs_terminfo_capabilities_size()` | a | KEEP |
| `dcs-shim.c` | `dcs_tweak_sixel_enabled()` | b | HOLD for module owner |
| `grid-shim.c` | `grid_resize_and_reflow()` | b | DELETE |
| `main-shim.c` | `main_shim_is_directory()` | a | KEEP |
| `notify-shim.c` | `notify_xstrjoin()` | a | KEEP |
| `notify-shim.c` | `notify_icon_at()` | b | HOLD for module owner |
| `notify-shim.c` | `notify_icon_count()` | b | HOLD for module owner |
| `notify-shim.c` | `notify_tll_free_and_free_actions()` | c | PORT (3 body lines) |
| `notify-shim.c` | `notify_active_first()` | c | PORT (4 body lines) |
| `notify-shim.c` | `notify_active_next()` | c | PORT (10 body lines) |
| `notify-shim.c` | `notify_conf_action_arg_configured()` | b | HOLD for module owner |
| `notify-shim.c` | `notify_spawn_expand_action_arg()` | c | PORT (7 body lines) |
| `notify-shim.c` | `notify_term_fdm()` | b | HOLD for module owner |
| `notify-shim.c` | `notify_active_remove()` | c | PORT (8 body lines) |
| `notify-shim.c` | `notify_wayl_terms_first()` | c | PORT (4 body lines) |
| `notify-shim.c` | `notify_wayl_terms_next()` | c | PORT (10 body lines) |
| `notify-shim.c` | `notify_term_window()` | b | HOLD for module owner |
| `notify-shim.c` | `notify_term_wayl()` | b | HOLD for module owner |
| `notify-shim.c` | `notify_term_kbd_focus()` | b | HOLD for module owner |
| `notify-shim.c` | `notify_term_window_title()` | b | HOLD for module owner |
| `notify-shim.c` | `notify_term_app_id()` | b | HOLD for module owner |
| `notify-shim.c` | `notify_conf_close_configured()` | b | HOLD for module owner |
| `notify-shim.c` | `notify_spawn_expand_close()` | c | PORT (5 body lines) |
| `notify-shim.c` | `notify_term_reaper()` | b | HOLD for module owner |
| `notify-shim.c` | `notify_active_push_back()` | c | PORT (3 body lines) |
| `notify-shim.c` | `notify_active_back()` | c | PORT (4 body lines) |
| `notify-shim.c` | `notify_active_len()` | c | PORT (3 body lines) |
| `notify-shim.c` | `notify_active_back_after_push()` | c | PORT (3 body lines) |
| `notify-shim.c` | `notify_actions_first()` | c | PORT (4 body lines) |
| `notify-shim.c` | `notify_actions_next()` | c | PORT (10 body lines) |
| `notify-shim.c` | `notify_actions_len()` | c | PORT (3 body lines) |
| `notify-shim.c` | `notify_actions_zero()` | c | PORT (3 body lines) |
| `notify-shim.c` | `notify_conf_command_configured()` | b | HOLD for module owner |
| `notify-shim.c` | `notify_conf_inhibit_when_focused()` | b | HOLD for module owner |
| `notify-shim.c` | `notify_conf_app_id()` | b | HOLD for module owner |
| `notify-shim.c` | `notify_spawn_expand_command()` | c | PORT (13 body lines) |
| `notify-shim.c` | `notify_pipe2()` | a | KEEP |
| `notify-shim.c` | `notify_fdm_add_stdout()` | c | PORT (3 body lines) |
| `osc-shim.c` | `osc_term_cwd_ptr()` | b | HOLD for module owner |
| `osc-shim.c` | `osc_seat_with_focus()` | c | PORT (7 body lines) |
| `osc-shim.c` | `osc_seat_serial()` | b | HOLD for module owner |
| `osc-shim.c` | `osc_osc52_copy_allowed()` | b | HOLD for module owner |
| `osc-shim.c` | `osc_osc52_paste_allowed()` | b | HOLD for module owner |
| `osc-shim.c` | `osc_ptmx_buffers_len()` | c | PORT (3 body lines) |
| `osc-shim.c` | `osc_fdm_epollout_ptmx()` | c | PORT (3 body lines) |
| `osc-shim.c` | `osc_theme_fg()` | c | PORT (1 body lines) |
| `osc-shim.c` | `osc_theme_bg()` | c | PORT (1 body lines) |
| `osc-shim.c` | `osc_theme_alpha()` | c | PORT (1 body lines) |
| `osc-shim.c` | `osc_theme_cursor_text()` | c | PORT (1 body lines) |
| `osc-shim.c` | `osc_theme_cursor_cursor()` | c | PORT (1 body lines) |
| `osc-shim.c` | `osc_theme_selection_bg()` | c | PORT (1 body lines) |
| `osc-shim.c` | `osc_theme_selection_fg()` | c | PORT (1 body lines) |
| `osc-shim.c` | `osc_theme_table_copy()` | c | PORT (3 body lines) |
| `osc-shim.c` | `osc_conf_colors_dark_use_custom_cursor()` | b | HOLD for module owner |
| `osc-shim.c` | `osc_notify_utf8_valid()` | a | KEEP |
| `osc-shim.c` | `osc_kitty_notif_get()` | b | HOLD for module owner |
| `osc-shim.c` | `osc_kitty_osc_bel()` | b | HOLD for module owner |
| `osc-shim.c` | `osc_kitty_conf_inhibit_when_focused()` | b | HOLD for module owner |
| `osc-shim.c` | `osc_xstrjoin()` | a | KEEP |
| `osc-shim.c` | `osc_xstrjoin3()` | a | KEEP |
| `osc-shim.c` | `osc_kitty_actions_push_back()` | c | PORT (3 body lines) |
| `osc-shim.c` | `osc_c32len()` | a | KEEP |
| `osc-shim.c` | `osc_conf_grapheme_width_method()` | b | HOLD for module owner |
| `shm-shim.c` | `shm_shim_wl_buffer_destroy()` | a | KEEP |
| `shm-shim.c` | `shm_shim_wl_shm_pool_destroy()` | a | KEEP |
| `shm-shim.c` | `shm_shim_wl_shm_create_pool()` | a | KEEP |
| `shm-shim.c` | `shm_shim_wl_shm_pool_create_buffer()` | a | KEEP |
| `shm-shim.c` | `shm_shim_wl_buffer_add_listener()` | a | KEEP |
| `shm-shim.c` | `page_size()` | c | PORT (14 body lines) |
| `shm-shim.c` | `shm_shim_page_size()` | a | KEEP |
| `shm-shim.c` | `shm_shim_stride_for_format()` | a | KEEP |
| `shm-shim.c` | `shm_shim_create_backing_file()` | a | KEEP |
| `shm-shim.c` | `shm_shim_probe_punch_hole()` | a | KEEP |
| `shm-shim.c` | `shm_shim_punch_hole()` | a | KEEP |
| `shm-shim.c` | `shm_shim_mmap_pool()` | a | KEEP |
| `shm-shim.c` | `shm_shim_seal_pool()` | a | KEEP |
| `shm-shim.c` | `shm_shim_format_constants()` | a | KEEP |
| `sixel-shim.c` | `sixel_get_scrolling()` | c | PORT (3 body lines) |
| `sixel-shim.c` | `sixel_get_use_private_palette()` | c | PORT (3 body lines) |
| `sixel-shim.c` | `sixel_get_cursor_right_of_graphics()` | c | PORT (3 body lines) |
| `sixel-shim.c` | `sixel_set_scrolling()` | c | PORT (3 body lines) |
| `sixel-shim.c` | `sixel_set_use_private_palette()` | c | PORT (3 body lines) |
| `sixel-shim.c` | `sixel_set_cursor_right_of_graphics()` | c | PORT (3 body lines) |
| `sixel-shim.c` | `sixel_get_palette_size()` | b | HOLD for module owner |
| `sixel-shim.c` | `sixel_set_palette_size()` | b | HOLD for module owner |
| `sixel-shim.c` | `sixel_get_max_width()` | b | HOLD for module owner |
| `sixel-shim.c` | `sixel_set_max_width()` | b | HOLD for module owner |
| `sixel-shim.c` | `sixel_get_max_height()` | b | HOLD for module owner |
| `sixel-shim.c` | `sixel_set_max_height()` | b | HOLD for module owner |
| `sixel-shim.c` | `sixel_get_palette()` | b | HOLD for module owner |
| `sixel-shim.c` | `sixel_set_palette()` | b | HOLD for module owner |
| `sixel-shim.c` | `sixel_get_private_palette()` | b | HOLD for module owner |
| `sixel-shim.c` | `sixel_set_private_palette()` | b | HOLD for module owner |
| `sixel-shim.c` | `sixel_get_shared_palette()` | b | HOLD for module owner |
| `sixel-shim.c` | `sixel_set_shared_palette()` | b | HOLD for module owner |
| `sixel-shim.c` | `sixel_wayl_do_linear_blending()` | c | PORT (3 body lines) |
| `sixel-shim.c` | `sixel_shm_chain_bit_depth()` | c | PORT (3 body lines) |
| `sixel-shim.c` | `sixel_wl_have_argb2101010()` | b | HOLD for module owner |
| `sixel-shim.c` | `sixel_wl_have_abgr2101010()` | b | HOLD for module owner |
| `sixel-shim.c` | `sixel_conf_sixel_palette_entries()` | b | HOLD for module owner |
| `sixel-shim.c` | `sixel_conf_sixel_palette_copy()` | c | PORT (6 body lines) |
| `sixel-shim.c` | `sixel_pixman_fmt_a8r8g8b8()` | a | KEEP |
| `sixel-shim.c` | `sixel_pixman_fmt_a2r10g10b10()` | a | KEEP |
| `sixel-shim.c` | `sixel_pixman_fmt_a2b10g10r10()` | a | KEEP |
| `sixel-shim.c` | `sixel_pixman_type_argb()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_mb_cur_max()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_urls_mode_active()` | c | PORT (3 body lines) |
| `terminal-shim.c` | `quirk_shim_subsurface_set_desync()` | a | KEEP |
| `terminal-shim.c` | `quirk_shim_subsurface_set_sync()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_grid_row_in_view()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_wl_surface_commit()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_grid_row_and_alloc()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_grid_row_absolute()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_erase_line()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_grid_row()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_term_reset_grapheme_state()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_precompose()` | c | PORT (12 body lines) |
| `terminal-shim.c` | `emoji_vs_compare()` | c | PORT (13 body lines) |
| `terminal-shim.c` | `terminal_shim_emoji_vs_width()` | c | PORT (22 body lines) |
| `terminal-shim.c` | `terminal_shim_fcft_glyph_pix()` | b | HOLD for module owner |
| `terminal-shim.c` | `terminal_shim_fcft_font_metrics()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_fcft_glyph_advance_x()` | b | HOLD for module owner |
| `terminal-shim.c` | `terminal_shim_fcft_font_name()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_fcft_font_antialias()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_fcft_font_ascent()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_fcft_font_descent()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_fcft_font_underline_position()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_fcft_font_underline_thickness()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_fcft_font_strikeout_position()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_fcft_font_strikeout_thickness()` | a | KEEP |
| `terminal-shim.c` | `render_shim_region_union_rect()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_surface_damage_buffer()` | c | PORT (6 body lines) |
| `terminal-shim.c` | `wayland_shim_subsurface_set_position()` | c | PORT (6 body lines) |
| `terminal-shim.c` | `render_shim_fcft_font_max_advance_x()` | a | KEEP |
| `terminal-shim.c` | `render_shim_fcft_font_height()` | a | KEEP |
| `terminal-shim.c` | `render_shim_fcft_has_text_run()` | a | KEEP |
| `terminal-shim.c` | `render_shim_fcft_text_run()` | a | KEEP |
| `terminal-shim.c` | `render_shim_fcft_text_run_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_set_opaque_region()` | c | PORT (19 body lines) |
| `terminal-shim.c` | `wayland_shim_set_opaque_region_rect()` | c | PORT (11 body lines) |
| `terminal-shim.c` | `render_shim_clip_rect()` | c | PORT (6 body lines) |
| `terminal-shim.c` | `render_shim_clip_clear()` | a | KEEP |
| `terminal-shim.c` | `render_shim_solid_fill()` | a | KEEP |
| `terminal-shim.c` | `render_shim_tiocswinsz()` | a | KEEP |
| `terminal-shim.c` | `render_shim_block_all_signals()` | a | KEEP |
| `terminal-shim.c` | `render_shim_set_thread_name()` | a | KEEP |
| `terminal-shim.c` | `render_shim_region_init()` | a | KEEP |
| `terminal-shim.c` | `render_shim_region_init_rect()` | a | KEEP |
| `terminal-shim.c` | `render_shim_region_fini()` | a | KEEP |
| `terminal-shim.c` | `render_shim_region_copy()` | a | KEEP |
| `terminal-shim.c` | `render_shim_region_clear()` | a | KEEP |
| `terminal-shim.c` | `render_shim_region_subtract()` | a | KEEP |
| `terminal-shim.c` | `render_shim_region_union()` | a | KEEP |
| `terminal-shim.c` | `render_shim_region_extents()` | a | KEEP |
| `terminal-shim.c` | `render_shim_region_rectangles()` | a | KEEP |
| `terminal-shim.c` | `render_shim_set_clip_region()` | a | KEEP |
| `terminal-shim.c` | `render_shim_presentation_feedback_destroy()` | a | KEEP |
| `terminal-shim.c` | `render_shim_single_pixel_buffer()` | a | KEEP |
| `terminal-shim.c` | `render_shim_image_unref()` | a | KEEP |
| `terminal-shim.c` | `render_shim_close_button()` | c | PORT (33 body lines) |
| `terminal-shim.c` | `render_shim_composite_op()` | a | KEEP |
| `terminal-shim.c` | `render_shim_composite()` | a | KEEP |
| `terminal-shim.c` | `render_shim_workers_lock()` | a | KEEP |
| `terminal-shim.c` | `render_shim_workers_unlock()` | a | KEEP |
| `terminal-shim.c` | `render_shim_curly_underline()` | c | PORT (25 body lines) |
| `terminal-shim.c` | `terminal_shim_linear_blending()` | c | PORT (3 body lines) |
| `terminal-shim.c` | `terminal_shim_grid_is_high_bit_depth()` | c | PORT (4 body lines) |
| `terminal-shim.c` | `terminal_shim_fcft_font_options_configure()` | c | PORT (18 body lines) |
| `terminal-shim.c` | `terminal_shim_thrd_err_as_string()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_wifexited()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_wexitstatus()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_wifsignaled()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_wtermsig()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_xdg_toplevel_set_maximized()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_xdg_toplevel_set_fullscreen()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_xdg_toplevel_set_minimized()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_xdg_toplevel_unset_maximized()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_xdg_toplevel_unset_fullscreen()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_xdg_toplevel_move()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_xdg_toplevel_resize()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_xdg_toplevel_show_window_menu()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_c32ncmp()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_c32ncasecmp()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_isc32print()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_isc32space()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_hasc32upper()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_region_add()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_surface_set_opaque_region()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_set_blur_region()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_activation_get_token()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_activation_token_set_serial()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_activation_token_set_surface()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_activation_token_commit()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_data_device_manager_get_device()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_primary_selection_device_manager_get_device()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_text_input_manager_get_text_input()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_data_source_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_data_offer_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_data_device_release()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_primary_selection_source_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_primary_selection_offer_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_primary_selection_device_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_cursor_shape_device_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_keyboard_release()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_pointer_release()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_touch_release()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_text_input_destroy()` | a | KEEP |
| `terminal-shim.c` | `selection_conf_word_delimiters()` | b | HOLD for module owner |
| `terminal-shim.c` | `selection_grid_row_in_view()` | a | KEEP |
| `terminal-shim.c` | `selection_seat_clipboard_data_offer()` | b | HOLD for module owner |
| `terminal-shim.c` | `selection_seat_primary_data_offer()` | b | HOLD for module owner |
| `terminal-shim.c` | `selection_conf_selection_target()` | b | HOLD for module owner |
| `terminal-shim.c` | `wayland_shim_data_source_create()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_data_source_offer()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_data_device_set_selection()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_primary_source_create()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_primary_source_offer()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_primary_device_set_selection()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_data_offer_receive()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_primary_offer_receive()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_data_offer_accept()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_data_offer_set_actions()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_data_offer_finish()` | a | KEEP |
| `terminal-shim.c` | `url_shim_regex_match()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_text_input_enable()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_text_input_disable()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_text_input_commit()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_text_input_set_content_type()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_text_input_set_cursor_rectangle()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_seat_release()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_xdg_toplevel_set_min_size()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_xdg_surface_set_window_geometry()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_ack_configure()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_display_get_registry()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_seat_get_keyboard()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_seat_get_pointer()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_seat_get_touch()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_cursor_shape_get_pointer()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_add_keyboard_listener()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_add_pointer_listener()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_add_touch_listener()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_iface_id()` | c | PORT (57 body lines) |
| `terminal-shim.c` | `wayland_shim_registry_bind()` | c | PORT (80 body lines) |
| `terminal-shim.c` | `wayland_shim_get_xdg_output()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_color_create_parametric_creator()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_color_params_set_tf_named()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_color_params_set_primaries_named()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_color_params_create()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_wm_base_pong()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_fixes_ack_global_remove()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_fcntl_getfl()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_fcntl_setfl()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_text_input_manager_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_toplevel_tag_manager_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_background_effect_manager_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_image_description_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_color_manager_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_system_bell_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_toplevel_icon_manager_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_single_pixel_manager_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_fractional_scale_manager_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_viewporter_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_cursor_shape_manager_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_activation_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_output_manager_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_wm_base_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_decoration_manager_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_presentation_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_data_device_manager_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_primary_selection_device_manager_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_shm_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_subcompositor_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_compositor_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_fixes_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_registry_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_fractional_scale_get()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_background_effect_get()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_xdg_wm_base_get_xdg_surface()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_xdg_surface_get_toplevel()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_xdg_toplevel_set_app_id()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_toplevel_tag_set()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_toplevel_icon_set()` | c | PORT (7 body lines) |
| `terminal-shim.c` | `wayland_shim_decoration_get()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_decoration_set_mode()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_surface_attach()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_surface_commit()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_surface_get_user_data()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_wl_callback_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_xdg_surface_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_xdg_toplevel_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_xdg_toplevel_decoration_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_fractional_scale_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_destroy_background_effect()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_xdg_activation_token_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_zxdg_output_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_wl_output_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_wl_output_release()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_compositor_create_surface()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_compositor_create_region()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_subcompositor_get_subsurface()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_viewporter_get_viewport()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_color_manager_get_surface()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_color_management_set_image_description()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_color_management_surface_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_surface_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_surface_set_user_data()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_surface_set_input_region()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_region_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_subsurface_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_viewport_destroy()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_xdg_system_bell_ring()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_xdg_activation_activate()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_surface_set_buffer_scale()` | a | KEEP |
| `terminal-shim.c` | `wayland_shim_viewport_set_destination()` | a | KEEP |
| `terminal-shim.c` | `terminal_shim_grid_row_absolute_in_view()` | a | KEEP |
| `terminal-shim.c` | `log_presentation_statistics()` | c | PORT (10 body lines) |
| `terminal-shim.c` | `render_presentation_ctx_term()` | a | KEEP |
| `terminal-shim.c` | `render_presentation_ctx_input()` | a | KEEP |
| `terminal-shim.c` | `render_presentation_ctx_commit()` | a | KEEP |
| `terminal-shim.c` | `render_shim_presentation_stat_add()` | c | PORT (10 body lines) |
| `terminal-shim.c` | `render_shim_presentation_commit_time()` | a | KEEP |
| `terminal-shim.c` | `render_shim_presentation_feedback_new()` | a | KEEP |
| `terminal-shim.c` | `render_shim_presentation_feedback_add()` | a | KEEP |
| `terminal-shim.c` | `render_shim_presentation_ctx_new()` | c | PORT (9 body lines) |
| `terminal-shim.c` | `render_shim_add_frame_callback()` | a | KEEP |
| `terminal-shim.c` | `render_shim_add_xcursor_callback()` | a | KEEP |
| `terminal-shim.c` | `render_shim_cursor_theme_get_cursor()` | a | KEEP |
| `terminal-shim.c` | `render_shim_cursor_image_0()` | a | KEEP |
| `terminal-shim.c` | `render_shim_cursor_image_0_buffer()` | a | KEEP |
| `terminal-shim.c` | `render_shim_pointer_set_cursor()` | a | KEEP |
| `terminal-shim.c` | `render_shim_cursor_shape_device_v1_set_shape()` | a | KEEP |
| `terminal-shim.c` | `render_shim_xdg_toplevel_set_title()` | a | KEEP |
| `terminal-shim.c` | `render_shim_callback_destroy()` | a | KEEP |
| `vt-shim.c` | `vt_call_ascii_printer()` | c | PORT (3 body lines) |
| `vt-shim.c` | `vt_tab_stops_insert_before()` | c | PORT (9 body lines) |
| `vt-shim.c` | `vt_tab_stops_push_back()` | c | PORT (3 body lines) |
| `vt-shim.c` | `vt_tab_stops_len()` | c | PORT (3 body lines) |
| `vt-shim.c` | `vt_tab_stops_back()` | c | PORT (3 body lines) |
| `vt-shim.c` | `vt_tab_stops_next_after()` | c | PORT (6 body lines) |
| `wayland-shim.c` | `wayland_shim_add_data_device_listener()` | a | KEEP |
| `wayland-shim.c` | `wayland_shim_add_primary_selection_device_listener()` | a | KEEP |
| `wayland-shim.c` | `wayland_shim_add_data_source_listener()` | a | KEEP |
| `wayland-shim.c` | `wayland_shim_add_primary_source_listener()` | a | KEEP |
| `wayland-shim.c` | `wayland_shim_add_data_offer_listener()` | a | KEEP |
| `wayland-shim.c` | `wayland_shim_add_primary_offer_listener()` | a | KEEP |
| `wayland-shim.c` | `wayland_shim_add_text_input_listener()` | a | KEEP |
| `wayland-shim.c` | `wayland_shim_add_registry_listener()` | a | KEEP |
| `wayland-shim.c` | `wayland_shim_add_shm_listener()` | a | KEEP |
| `wayland-shim.c` | `wayland_shim_add_wm_base_listener()` | a | KEEP |
| `wayland-shim.c` | `wayland_shim_add_seat_listener()` | a | KEEP |
| `wayland-shim.c` | `wayland_shim_keyboard_leave()` | a | KEEP |
| `wayland-shim.c` | `wayland_shim_pointer_leave()` | a | KEEP |
| `wayland-shim.c` | `wayland_shim_add_output_listener()` | a | KEEP |
| `wayland-shim.c` | `wayland_shim_add_xdg_output_monitor_listener()` | a | KEEP |
| `wayland-shim.c` | `wayland_shim_add_presentation_listener()` | a | KEEP |
| `wayland-shim.c` | `wayland_shim_add_color_manager_listener()` | a | KEEP |
| `wayland-shim.c` | `wayland_shim_add_background_manager_listener()` | a | KEEP |
| `wayland-shim.c` | `wayland_shim_add_surface_listener()` | a | KEEP |
| `wayland-shim.c` | `wayland_shim_add_fractional_scale_listener()` | a | KEEP |
| `wayland-shim.c` | `wayland_shim_add_xdg_surface_listener()` | a | KEEP |
| `wayland-shim.c` | `wayland_shim_add_xdg_toplevel_listener()` | a | KEEP |
| `wayland-shim.c` | `wayland_shim_add_decoration_listener()` | a | KEEP |
| `wayland-shim.c` | `wayland_shim_add_activation_token_listener()` | a | KEEP |
| `xmalloc-shim.c` | `xasprintf()` | a | KEEP |
| `xsnprintf-shim.c` | `xsnprintf()` | a | KEEP |
