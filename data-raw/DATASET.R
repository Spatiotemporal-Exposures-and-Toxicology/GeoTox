library(tidyverse)
library(readxl)
library(httk)
library(sf)

# This dataset is documented in R/data.R and vignettes/package_data.Rmd

rm(list = ls())
geo_tox_data <- list()

################################################################################
## Chemical data
################################################################################

########################################
### Exposure data
########################################

# filename <- "2019_Toxics_Exposure_Concentrations.xlsx"
# tmp <- tempfile(filename)
# download.file(
#   paste0("https://www.epa.gov/system/files/documents/2022-12/", filename),
#   tmp
# )
# exposure <- read_xlsx(tmp)
exposure <- read_xlsx("~/dev/GeoTox/data-new/2019_Toxics_Exposure_Concentrations.xlsx")

# Normalization function
min_max_norm = function(x) {
  min_x <- min(x, na.rm = TRUE)
  max_x <- max(x, na.rm = TRUE)
  if (min_x == max_x) {
    rep(0, length(x))
  } else {
    (x - min_x) / (max_x - min_x)
  }
}

geo_tox_data$exposure <- exposure %>%
  # North Carolina counties
  filter(State == "NC", !grepl("0$", FIPS)) %>%
  # Aggregate chemicals by county
  summarize(across(-c(State:Tract), c(mean, sd)), .by = FIPS) %>%
  pivot_longer(-FIPS, names_to = "chemical") %>%
  mutate(
    stat = if_else(grepl("_1$", chemical), "mean", "sd"),
    chemical = gsub('.{2}$', '', chemical)
  ) %>%
  pivot_wider(names_from = stat) %>%
  # Normalize concentrations
  mutate(norm = min_max_norm(mean), .by = chemical)

########################################
### Dose-response data
########################################

load("~/dev/GeoTox/data-new/ICE_Invitro_DB/aeid_851_1000_ICE_cHTS_chems_for_Kyle_231120.RData")

geo_tox_data$dose_response <- cdat2_h %>%
  # Keep "LTEA_HepaRG_CYP1A1_up" assay
  filter(aenm == "LTEA_HepaRG_CYP1A1_up") %>%
  # Keep selected columns
  select(chnm, casn, logc, resp)

########################################
### Subset dose-response and exposure data
########################################

cHTS <- read_tsv("~/dev/GeoTox/data-new/cHTS2022_invitrodb34_20220302.txt")

casn_hits <- cHTS %>%
  filter(
    Assay == "LTEA_HepaRG_CYP1A1_up",
    Endpoint == "Call",
    Response == "Active"
  ) %>%
  distinct(CASRN) %>% pull()

geo_tox_data$exposure <- geo_tox_data$exposure %>%
  left_join(
    geo_tox_data$dose_response %>%
      distinct(chnm, casn) %>%
      mutate(chnm = toupper(chnm)),
    by = join_by(chemical == chnm)
  ) %>%
  # Remove chemicals not found in dose-response
  na.omit() %>%
  # Keep cHTS active chemicals
  filter(casn %in% casn_hits)

# Update dose-response to keep only those remaining in exposure
geo_tox_data$dose_response <- geo_tox_data$dose_response %>%
  filter(casn %in% geo_tox_data$exposure$casn)

################################################################################
## Population data
################################################################################

########################################
### Age
########################################

age <- read_csv("~/dev/GeoTox/data-new/cc-est2019-alldata-37.csv")

geo_tox_data$age <- age %>%
  # 7/1/2019 population estimate
  filter(YEAR == 12) %>%
  # Create FIPS
  mutate(FIPS = str_c(STATE, COUNTY)) %>%
  # Keep selected columns
  select(FIPS, AGEGRP, TOT_POP)

########################################
### Obesity
########################################

places <- read_csv("~/dev/GeoTox/data-new/PLACES__County_Data__GIS_Friendly_Format___2020_release.csv")

# Convert confidence interval to standard deviation
extract_SD <- function(x) {
  range <- as.numeric(str_split_1(str_sub(x, 2, -2), ","))
  diff(range) / 3.92
}

geo_tox_data$obesity <- places %>%
  # North Carolina Counties
  filter(StateAbbr == "NC") %>%
  # Select obesity data
  select(FIPS = CountyFIPS, OBESITY_CrudePrev, OBESITY_Crude95CI) %>%
  # Change confidence interval to standard deviation
  rowwise() %>%
  mutate(OBESITY_SD = extract_SD(OBESITY_Crude95CI)) %>%
  ungroup() %>%
  select(-OBESITY_Crude95CI)

########################################
### Steady-state plasma concentration (Css)
########################################

load_sipes2017()

set.seed(2345)
n_samples <- 50

# Define population demographics for httk simulation
# TODO where do these age groups come from?
# They don't match those from the age data source or the table in simulate_inhalation_rate().
# Are they age groups specific to httk?
pop_demo <- cross_join(
  tibble(
    age_group = list(
      c(0, 2), c(3, 5), c(6, 10), c(11, 15), c(16, 20), c(21, 30),
      c(31, 40), c(41, 50), c(51, 60), c(61, 70), c(71, 100)
    )
  ),
  tibble(
    weight = c("Normal", "Obese")
  )
) %>%
  # Create column of lower age_group values
  rowwise() %>%
  mutate(age_min = age_group[1]) %>%
  ungroup()

# Create wrapper function around httk steps
simulate_css <- function(
    chem.cas, agelim_years, weight_category, samples, verbose = TRUE
) {

  if (verbose) {
    cat(
      chem.cas,
      paste0("(", paste(agelim_years, collapse = ", "), ")"),
      weight_category,
      "\n"
    )
  }

  httkpop <- list(
    method = "vi",
    gendernum = NULL,
    agelim_years = agelim_years,
    agelim_months = NULL,
    weight_category = weight_category,
    reths = c(
      "Mexican American",
      "Other Hispanic",
      "Non-Hispanic White",
      "Non-Hispanic Black",
      "Other"
    )
  )

  css <- try(
    suppressWarnings({
      mcs <- create_mc_samples(
        chem.cas = chem.cas,
        samples = samples,
        httkpop.generate.arg.list = httkpop,
        suppress.messages = TRUE
      )

      calc_analytic_css(
        chem.cas = chem.cas,
        parameters = mcs,
        model = "3compartmentss",
        suppress.messages = TRUE
      )
    }),
    silent = TRUE
  )

  # Return
  if (is(css, "try-error")) {
    warning(paste0("simulate_css failed to generate data for CASN ", chem.cas))
    list(NA)
  } else {
    list(css)
  }
}

# Get CASN
casn <- unique(geo_tox_data$dose_response$casn)

# Simulate Css values
simulated_css <- lapply(casn, function(chem.cas) {
  pop_demo %>%
    rowwise() %>%
    mutate(
      css = simulate_css(.env$chem.cas, age_group, weight, .env$n_samples)
    ) %>%
    ungroup()
})
simulated_css <- setNames(simulated_css, casn)

# Get median Css values for each age_group
simulated_css <- lapply(
  simulated_css,
  function(cas_df) {
    cas_df %>%
      nest(.by = age_group) %>%
      mutate(
        age_median_css = sapply(data, function(df) median(unlist(df$css)))
      ) %>%
      unnest(data)
  }
)

# Get median Css values for each weight
simulated_css <- lapply(
  simulated_css,
  function(cas_df) {
    cas_df %>%
      nest(.by = weight) %>%
      mutate(
        weight_median_css = sapply(data, function(df) median(unlist(df$css)))
      ) %>%
      unnest(data) %>%
      arrange(age_min, weight)
  }
)

geo_tox_data$simulated_css <- simulated_css

########################################
### Subset exposure, dose-response and Css data
########################################

idx <- sapply(
  lapply(geo_tox_data$simulated_css, "[[", "age_median_css"),
  function(x) any(is.na(x))
)

if (any(idx)) {

  idx <- which(!idx)
  casn <- names(geo_tox_data$simulated_css)[idx]

  geo_tox_data$exposure <- geo_tox_data$exposure %>%
    filter(casn %in% .env$casn)

  geo_tox_data$dose_response <- geo_tox_data$dose_response %>%
    filter(casn %in% .env$casn)

  geo_tox_data$simulated_css <- geo_tox_data$simulated_css[idx]

}

################################################################################
## County/State boundaries
################################################################################

county <- st_read("~/dev/GeoTox/data-new/cb_2019_us_county_5m/cb_2019_us_county_5m.shp")
state <- st_read("~/dev/GeoTox/data-new/cb_2019_us_state_5m/cb_2019_us_state_5m.shp")

geo_tox_data$boundaries <- list(
  county = county %>%
    filter(STATEFP == 37) %>%
    select(FIPS = GEOID, geometry),
  state = state %>%
    filter(STATEFP == 37) %>%
    select(geometry)
)

################################################################################
## Save
################################################################################

usethis::use_data(geo_tox_data, overwrite = TRUE)
