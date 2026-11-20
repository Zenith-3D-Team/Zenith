-- How much faster a sprinting character runs (0.5: half as fast again). A map setting, so the
-- server's owner decides it and every player has the same.
data:extend({
  {
    type = "double-setting",
    name = "zenith-sprint-bonus",
    setting_type = "runtime-global",
    default_value = 0.5,
    minimum_value = 0,
    maximum_value = 2,
  },
})
