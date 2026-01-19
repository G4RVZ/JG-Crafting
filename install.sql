CREATE TABLE `crafting_benches` (
  `id` int(11) NOT NULL,
  `bench_type` varchar(50) NOT NULL,
  `x` double NOT NULL,
  `y` double NOT NULL,
  `z` double NOT NULL,
  `heading` double NOT NULL,
  `owner` varchar(50) DEFAULT NULL,
  `job` varchar(50) DEFAULT NULL,
  `min_grade` int(11) DEFAULT 0,
  `gang` varchar(50) DEFAULT NULL,
  `gang_grade` int(11) NOT NULL DEFAULT 0,
  `restrict_item` varchar(50) DEFAULT NULL,
  `restrict_amount` int(11) NOT NULL DEFAULT 1
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_general_ci;