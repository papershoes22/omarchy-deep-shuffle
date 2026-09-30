-- SoundCloud Likes Player: the full-player window ("sclikes player", a Quickshell FloatingWindow).
-- Optional. Load it from ~/.config/hypr/hyprland.lua with:
--   dofile(os.getenv("HOME") .. "/.config/omarchy/plugins/io.github.papershoes22.sclikes/hypr/sclikes.lua")

-- On a laptop's built-in screen (eDP-1 here; check `hyprctl monitors`) it floats, centered, instead of
-- squeezing into the tiling layout. On other monitors it tiles like any other window.
o.window({ title = "^sclikes player$", workspace = "m[eDP-1]" },
  { float = true, size = { "monitor_w*0.9", "monitor_h*0.88" }, center = true })
