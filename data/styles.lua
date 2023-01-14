local styles = data.raw['gui-style'].default

styles.ctron_title_dragbar = {
    type = "empty_widget_style",
    parent = "draggable_space_header",

    height = 24,

    left_margin = 4,
    right_margin = 4,

    horizontally_stretchable = "on"
}

styles.ctron_frame_button = {
    type = "button_style",
    parent = "frame_button",

    height = 24,
    minimal_width = 0,

    left_padding = 8,
    right_padding = 8,

    font = "heading-2",
    default_font_color = {0.9, 0.9, 0.9},
    hovered_font_color = {0, 0, 0},
    selected_font_color = {0, 0, 0},
    disabled_font_color = {0.701961, 0.701961, 0.701961}
}

styles.ctron_frame_dropdown = {
    type = "dropdown_style",
    parent = "dropdown",
    
    height = 24,
    minimal_width = 80,

    top_padding = -4,
    left_padding = 8,
    right_padding = 2,
    
    button_style = {
        type = "button_style",
        parent = "ctron_frame_button",
    },

    list_box_style = {
        type = "list_box_style",

        item_style = {
            type = "button_style",
            parent = "ctron_frame_button"
        }
    }
}
