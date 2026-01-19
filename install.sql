CREATE TABLE IF NOT EXISTS crafting_benches (
    id INT AUTO_INCREMENT PRIMARY KEY,
    bench_type VARCHAR(50) NOT NULL,
    x DOUBLE NOT NULL,
    y DOUBLE NOT NULL,
    z DOUBLE NOT NULL,
    heading DOUBLE NOT NULL,
    owner VARCHAR(50),
    job VARCHAR(50),
    min_grade INT DEFAULT 0,
    gang VARCHAR(50) NULL,
    gang_grade INT NOT NULL DEFAULT 0,
    restrict_item VARCHAR(50) NULL,
    restrict_amount INT NOT NULL DEFAULT 1;
);
