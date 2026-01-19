# JG-Crafting – Placeable Crafting Benches

A **QBCore And Qbox crafting system** that supports **placeable crafting benches as items**, with **ox_lib placement**, **database persistence**, and **job / grade restricted pickup**.

This resource is designed to work with **QBCore**, **Qbox**, **ox_lib**, and either **qb-target** or **ox_target**, while supporting **qb-inventory** or **ox_inventory** automatically.

---

## ✨ Features

* 🧰 Crafting benches are **inventory items**
* 📍 Place benches **anywhere in the world**
* 🔄 **Rotation, preview, confirm / cancel** placement (ox_lib)
* 💾 **Database saved** (persistent after restart)
* 👮 **Job & grade restricted pickup**
* 🎯 Supports **qb-target** OR **ox_target**
* 📦 Supports **qb-inventory** OR **ox_inventory**
* 🔁 Benches automatically reload on resource/server restart

---

## 📦 Dependencies

**Required:**

* `qb-core`
* `ox_lib`
* `oxmysql`

**One of the following (auto-detected):**

* `qb-target` **or** `ox_target`

**One of the following (auto-detected):**

* `qb-inventory` **or** `ox_inventory`

---

## 📁 Installation

1. **Download / clone** this repository
2. Place it into your `resources` folder
3. Ensure dependencies load first

```cfg
ensure ox_lib
ensure oxmysql
ensure qb-core
ensure JG-Crafting
```

---

## 🧱 Database Setup

Run the following SQL in your database:

```sql
CREATE TABLE IF NOT EXISTS crafting_benches (
    id INT AUTO_INCREMENT PRIMARY KEY,
    bench_type VARCHAR(50) NOT NULL,
    x DOUBLE NOT NULL,
    y DOUBLE NOT NULL,
    z DOUBLE NOT NULL,
    heading DOUBLE NOT NULL,
    job VARCHAR(50),
    min_grade INT DEFAULT 0
);
```

---

## 📦 Item Setup

Add the crafting bench item to **qb-core/shared/items.lua**:

```lua
['crafting_bench'] = {
    name = 'crafting_bench',
    label = 'Crafting Bench',
    weight = 5000,
    type = 'item',
    image = 'crafting_bench.png',
    unique = false,
    useable = true,
}
```

Make sure the item is **usable** and triggers the client event:

```lua
QBCore.Functions.CreateUseableItem('crafting_bench', function(source)
    TriggerClientEvent('JG-Crafting:client:PlaceBench', source, 'weaponbench')
end)
```

---

## ⚙️ Configuration

### Bench Types

Define your crafting benches in `config.lua`:

```lua
Config.BenchTypes = {
    weaponbench = {
        label = 'Weapon Crafting Bench',
        prop = 'gr_prop_gr_bench_04a',

        pickup = {
            job = 'police',
            minGrade = 3
        },

        items = {
            {
                name = 'weapon_pistol',
                label = 'Pistol',
                time = 7000,
                requires = {
                    steel = 20,
                    plast
```
