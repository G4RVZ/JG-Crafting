Config = {}

-- ======================
-- DISCORD WEBHOOK LOGS
-- ======================
Config.Webhooks = {
    enabled = true,

    -- If you want one webhook for everything, put the same URL in each.
    urls = {
        placed            = "https://discord.com/api/webhooks/1462553570623754374/xDssubVBxY76kuDvWTebUCrBvLJ9f4PuKejQsPUMYf7Yt0ORtgDAsucJtQDzYW7rRhi0",
        moved             = "https://discord.com/api/webhooks/1462553570623754374/xDssubVBxY76kuDvWTebUCrBvLJ9f4PuKejQsPUMYf7Yt0ORtgDAsucJtQDzYW7rRhi0",
        crafted           = "https://discord.com/api/webhooks/1462553570623754374/xDssubVBxY76kuDvWTebUCrBvLJ9f4PuKejQsPUMYf7Yt0ORtgDAsucJtQDzYW7rRhi0",
        deleted_with_item = "https://discord.com/api/webhooks/1462553570623754374/xDssubVBxY76kuDvWTebUCrBvLJ9f4PuKejQsPUMYf7Yt0ORtgDAsucJtQDzYW7rRhi0",
        deleted_no_item   = "https://discord.com/api/webhooks/1462553570623754374/xDssubVBxY76kuDvWTebUCrBvLJ9f4PuKejQsPUMYf7Yt0ORtgDAsucJtQDzYW7rRhi0",
        dismantled        = "https://discord.com/api/webhooks/1462553570623754374/xDssubVBxY76kuDvWTebUCrBvLJ9f4PuKejQsPUMYf7Yt0ORtgDAsucJtQDzYW7rRhi0",
    },

    botName   = "Crafting Bench Logs",
    botAvatar = "", -- optional image url

    color = {
        placed            = 3066993,   -- green
        moved             = 15105570,  -- orange
        crafted           = 3447003,   -- blue
        deleted_with_item = 15158332,  -- red-ish
        deleted_no_item   = 10038562,  -- dark red
        dismantled        = 10181046,  -- purple-ish
    }
}

-- ======================
-- GENERAL
-- ======================
-- auto = detect by running resources
-- qb   = force qb-menu / qb-input / qb-progressbar / qb-target
-- ox   = force ox_lib / ox_target / ox_inventory (if Inventory=ox)
Config.Systems = {
    Menu      = "ox",
    Input     = "ox",
    Progress  = "ox",
    Target    = "ox",
    Inventory = "ox",
    AdminMenu = "ox" -- optional, defaults to Menu if auto
}

Config.DefaultCraftTime = 7000

-- QB progressbar uses animDict/anim/flags
-- ox_lib progressCircle uses dict/clip/flag (client converts automatically)
Config.Crafting = {
    animDict = "mini@repair",
    anim     = "fixing_a_player",
    flags    = 49
}

-- ======================
-- PREVIEW SETTINGS
-- ======================
Config.Preview = {
    rotateSpeed = 0.3
}

Config.PreviewCam = {
    enabled = true,

    default = {
        offset       = vector3(0.0, -1.25, 0.90),
        lookAtOffset = vector3(0.0, 0.0, 0.12),
        fov          = 45.0,
        interpMs     = 650
    },

    weaponbench = {
        offset       = vector3(0.0, -1.15, 2.00),
        lookAtOffset = vector3(0.0, 0.0, 1.10),
        fov          = 60.0,
        interpMs     = 650
    },

    mechanicbench = { -- prop_tool_bench02
        offset       = vector3(1.15, 0.0, 1.45),
        lookAtOffset = vector3(0.0, 0.0, 0.75),
        fov          = 60.0,
        interpMs     = 650
    },

    dismantlerbench = {
        offset       = vector3(0.0, -1.15, 2.00),
        lookAtOffset = vector3(0.0, 0.0, 1.10),
        fov          = 60.0,
        interpMs     = 650
    }
}

-- ======================
-- BENCH TYPES
-- ======================
Config.BenchTypes = {
    weaponbench = {
        item         = "crafting_bench",    
        label        = "Weapon Crafting Bench",
        prop         = "gr_prop_gr_bench_04a",
        mode         = "craft", -- (optional) default behavior
        placeItem    = "crafting_bench",
        placeZOffset = -0.98,

        pickup = {
            job      = "police",
            minGrade = 3
        },

        items = {
            {
                name   = "weapon_pistol",
                label  = "Pistol",
                time   = 7000,
                amount = 1,

                requires = {
                    steel   = 20,
                    plastic = 15
                },

                preview = {
                    model    = "w_pi_pistol",
                    offset   = vector3(0.0, 0.0, 1.05),
                    rotation = vector3(0.0, 0.0, 0.0),
                    rotate   = true
                }
            },
            {
                name   = "weapon_stungun",
                label  = "Taser",
                time   = 7000,
                amount = 1,

                requires = {
                    steel   = 10,
                    plastic = 5
                },

                preview = {
                    model    = "w_pi_stungun",
                    offset   = vector3(0.0, 0.0, 1.05),
                    rotation = vector3(0.0, 0.0, 0.0),
                    rotate   = true
                }
            }
        }
    },

    mechanicbench = {
        item      = "mechanic_bench",
        label     = "Mechanic Crafting Bench",
        prop      = "prop_tool_bench02",
        mode      = "craft",
        placeItem = "mechanic_bench",

        pickup = {
            job      = "mechanic",
            minGrade = 2
        },

        items = {
            {
                name   = "repairkit",
                label  = "Repair Kit",
                time   = 5000,
                amount = 1,

                requires = {
                    steel  = 5,
                    rubber = 3
                },

                preview = {
                    model    = "v_ind_cs_toolbox4",
                    offset   = vector3(0.0, 0.0, 1.05),
                    rotation = vector3(0.0, 0.0, 0.0),
                    rotate   = true
                }
            }
        }
    },

    dismantlerbench = {
        label        = "Dismantler Bench",
        prop         = "gr_prop_gr_bench_04a",
        mode         = "dismantle",
        placeItem    = "dismantler_bench",
        placeZOffset = -0.98,

        pickup = {
            job      = "mechanic",
            minGrade = 2
        },

        -- NOTE:
        -- You removed `returns` from items. Server auto-calculates returns from the craft recipe
        -- in other benches using `requires`. You can still add `returns = { ... }` per item if you
        -- want manual overrides.
        items = {
            {
                name         = "weapon_pistol",
                label        = "Pistol",
                time         = 4000,
                removeAmount = 1,

                preview = {
                    model    = "w_pi_pistol",
                    offset   = vector3(0.0, 0.0, 1.05),
                    rotation = vector3(0.0, 0.0, 0.0),
                    rotate   = true
                }
            },
            {
                name         = "repairkit",
                label        = "Repair Kit",
                time         = 2500,
                removeAmount = 1,

                preview = {
                    model    = "v_ind_cs_toolbox4",
                    offset   = vector3(0.0, 0.0, 1.05),
                    rotation = vector3(0.0, 0.0, 0.0),
                    rotate   = true
                }
            }
        }
    }
}

-- ======================
-- DISMANTLING
-- ======================
Config.Dismantle = {
    -- Multiplies every return amount (handy for different servers)
    -- Example: 1.0 = normal, 0.5 = half returns, 2.0 = double returns
    returnMultiplier = 1.0,

    -- Round down after multiplier (recommended)
    roundDown = true
}
