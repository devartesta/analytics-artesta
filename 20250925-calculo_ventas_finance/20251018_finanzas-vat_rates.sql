-- 1) Esquema
CREATE SCHEMA IF NOT EXISTS finance;

-- 2) Tabla única de VAT por país + rango de ZIP
DROP TABLE IF EXISTS finance.vat_rates;
CREATE TABLE finance.vat_rates (
    shipping_country_code CHAR(2) NOT NULL,     -- ISO-3166-1 alpha-2 (ej. ES, PT, FR)
    zip_ini BIGINT NOT NULL,                    -- inicio de rango (normalizado a dígitos)
    zip_fin BIGINT NOT NULL,                    -- fin de rango (incluido)
    standard_rate NUMERIC(5,2) NOT NULL,        -- VAT estándar aplicable en ese tramo
    updated_date DATE NOT NULL DEFAULT CURRENT_DATE,

    CHECK (zip_ini <= zip_fin),
    PRIMARY KEY (shipping_country_code, zip_ini, zip_fin)
);

-- Índice de ayuda (busca por país + BETWEEN)
-- (Suficiente para tu patrón de consulta; si algún día quieres evitar solapamientos,
--  podemos migrar a un GENERATED int8range + EXCLUDE con btree_gist.)
CREATE INDEX IF NOT EXISTS ix_vat_rates_country_zip
  ON finance.vat_rates (shipping_country_code, zip_ini, zip_fin);

-- 3) Carga base de países UE (estándar aprox. 2025). Ajusta si cambia normativa
INSERT INTO finance.vat_rates (shipping_country_code, zip_ini, zip_fin, standard_rate)
VALUES
('AT', -1, 999999999, 20.00),
('BE', -1, 999999999, 21.00),
('BG', -1, 999999999, 20.00),
('HR', -1, 999999999, 25.00),
('CY', -1, 999999999, 19.00),
('CZ', -1, 999999999, 21.00),
('DK', -1, 999999999, 25.00),
('EE', -1, 999999999, 22.00),
('FI', -1, 999999999, 24.00),
('FR', -1, 999999999, 20.00),
('DE', -1, 999999999, 19.00),
('GR', -1, 999999999, 24.00),
('HU', -1, 999999999, 27.00),
('IE', -1, 999999999, 23.00),
('IT', -1, 999999999, 22.00),
('LV', -1, 999999999, 21.00),
('LT', -1, 999999999, 21.00),
('LU', -1, 999999999, 17.00),
('MT', -1, 999999999, 18.00),
('NL', -1, 999999999, 21.00),
('PL', -1, 999999999, 23.00),
('PT', -1, 999999999, 23.00),
('RO', -1, 999999999, 19.00),
('SK', -1, 999999999, 20.00),
('SI', -1, 999999999, 22.00),
('ES', -1, 999999999, 21.00),
('SE', -1, 999999999, 25.00);


-- 4) Overrides España (ES):
-- Canarias (Las Palmas 35000–35999, S/C Tenerife 38000–38999)
INSERT INTO finance.vat_rates (shipping_country_code, zip_ini, zip_fin, standard_rate, updated_date)
VALUES
('ES', 35000, 35999, 0.00, CURRENT_DATE),
('ES', 38000, 38999, 0.00, CURRENT_DATE);

-- Ceuta (51000–51999) y Melilla (52000–52999)
INSERT INTO finance.vat_rates (shipping_country_code, zip_ini, zip_fin, standard_rate, updated_date)
VALUES
('ES', 51000, 51999, 0.00, CURRENT_DATE),
('ES', 52000, 52999, 0.00, CURRENT_DATE);
