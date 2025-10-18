-- 1) Tabla única de VAT por país + rango de ZIP
DROP TABLE IF EXISTS finance.vat_rates;
CREATE TABLE finance.vat_rates (
    shipping_country_code CHAR(2) NOT NULL,     -- ISO-3166-1 alpha-2 (ej. ES, PT, FR)
    zip_ini BIGINT NOT NULL,                    -- inicio de rango (normalizado a dígitos)
    zip_fin BIGINT NOT NULL,                    -- fin de rango (incluido)
    standard_rate NUMERIC(5,4) NOT NULL,        -- VAT estándar aplicable en ese tramo (decimal)
    updated_date DATE NOT NULL DEFAULT CURRENT_DATE,

    CHECK (zip_ini <= zip_fin),
    PRIMARY KEY (shipping_country_code, zip_ini, zip_fin)
);

-- Índice de ayuda (busca por país + BETWEEN)
CREATE INDEX IF NOT EXISTS ix_vat_rates_country_zip
  ON finance.vat_rates (shipping_country_code, zip_ini, zip_fin);

-- 3) España
INSERT INTO finance.vat_rates (shipping_country_code, zip_ini, zip_fin, standard_rate, updated_date)
VALUES
('ES', -1, 34999, 0.21, CURRENT_DATE),
('ES', 35000, 35999, 0.07, CURRENT_DATE),
('ES', 36000, 37999, 0.21, CURRENT_DATE),
('ES', 38000, 38999, 0.07, CURRENT_DATE),
('ES', 39000, 50999, 0.21, CURRENT_DATE),
('ES', 51000, 51999, 0.00, CURRENT_DATE),
('ES', 52000, 52999, 0.00, CURRENT_DATE),
('ES', 53000, 999999999, 0.21, CURRENT_DATE);

-- 4) Resto UE (estándar aprox. 2025)
INSERT INTO finance.vat_rates (shipping_country_code, zip_ini, zip_fin, standard_rate)
VALUES
('AT', -1, 999999999, 0.20),
('BE', -1, 999999999, 0.21),
('BG', -1, 999999999, 0.20),
('HR', -1, 999999999, 0.25),
('CY', -1, 999999999, 0.19),
('CZ', -1, 999999999, 0.21),
('DK', -1, 999999999, 0.25),
('EE', -1, 999999999, 0.22),
('FI', -1, 999999999, 0.24),
('FR', -1, 999999999, 0.20),
('DE', -1, 999999999, 0.19),
('GR', -1, 999999999, 0.24),
('HU', -1, 999999999, 0.27),
('IE', -1, 999999999, 0.23),
('IT', -1, 999999999, 0.22),
('LV', -1, 999999999, 0.21),
('LT', -1, 999999999, 0.21),
('LU', -1, 999999999, 0.17),
('MT', -1, 999999999, 0.18),
('NL', -1, 999999999, 0.21),
('PL', -1, 999999999, 0.23),
('PT', -1, 999999999, 0.23),
('RO', -1, 999999999, 0.19),
('SK', -1, 999999999, 0.20),
('SI', -1, 999999999, 0.22),
('SE', -1, 999999999, 0.25);

SELECT * FROM finance.vat_rates;
