###############################################################################
# Calculates mean precipitation for GRP countries.
###############################################################################

source('../0_settings.R')

library(tools)
library(stringr)
library(raster)
library(lubridate)
library(dplyr)
library(rgeos)
library(foreach)
library(doParallel)
library(spatial.tools)
library(maptools)

# Select the start and end dates for the data to include in this analysis
start_date <- as.Date('1985/1/1') # Inclusive
end_date <- as.Date('2014/12/1') # Exclusive

cl  <- makeCluster(3)
registerDoParallel(cl)

in_folder <- file.path(prefix, "GRP", "CHIRPS-2.0")
shp_folder <- file.path(prefix, "GRP", "Boundaries")
stopifnot(file_test('-d', in_folder))
stopifnot(file_test('-d', shp_folder))

countries <- read.csv(file.path(prefix, "GRP", "DataTables", "GRP_Countries.csv"))
regions <- read.csv(file.path(prefix, "GRP", "DataTables", "GRP_Regions.csv"))
countries <- merge(countries, regions)
countries$Region_Name <- gsub(' ', '', countries$Region_Name)

# Read in seasonal assignments
season_key <- read.csv(file.path(prefix, "GRP", "DataTables", "Rainy_Seasons.csv"))
season_key$ISO3 <- as.character(season_key$ISO3)

aoi_polygons <- readShapeSpatial(file.path(shp_folder, 'GRP_Countries.shp'))
foreach(region=unique(countries$Region_Name), .inorder=FALSE, .combine=rbind) %do% {

    chirps_file <- file.path(in_folder,
                             paste0(region, '_CHIRPS_monthly_198101-201412.tif'))
    timestamp()
    print(region)
    these_countries <- aoi_polygons[aoi_polygons$ISO3 %in% countries[countries$Region_Name == region, ]$ISO3, ]
    foreach (n=1:nrow(these_countries), .inorder=FALSE,
             .packages=c('raster', 'stringr', 'dplyr', 'spatial.tools', 
                         'rgdal', 'lubridate', 'tools')) %dopar% {
        this_country <- these_countries[n, ]

        name <- str_extract(chirps_file, '^[a-zA-Z]*')

        inc_subyrs_str <- season_key[season_key$ISO3 == this_country$ISO3, ]$RS_1_Months
        t0 <- as.numeric(str_extract(inc_subyrs_str, '^[0-9]*'))
        tf <- as.numeric(str_extract(inc_subyrs_str, '[0-9]*$'))
        inc_subyrs <- seq(t0, tf)
        stopifnot((min(inc_subyrs) >= 1) & max(inc_subyrs) <=12)

        # Calculate the band numbers that are needed
        dates <- seq(as.Date('1981/1/1'), as.Date('2014/12/1'), by='months')
        band_nums <- c(1:length(dates))[(dates >= start_date) & (dates <= end_date)]
        dates <- dates[band_nums]
        n_years <- length(unique(year(dates)))
        # Extract only band numbers for the included months, so we are not 
        # read/writing extra data
        subyr_ind <- rep(seq(0, (n_years-1))*12, each=length(inc_subyrs)) + rep(inc_subyrs, n_years)
        band_nums <- band_nums[subyr_ind]
        dates <- dates[subyr_ind]

        season_string <- paste0('_', paste(inc_subyrs, collapse='-'))

        start_date_text <- format(start_date, '%Y%m%d')
        end_date_text <- format(end_date, '%Y%m%d')
        out_basename <- paste0(gsub('[0-9-]{6}-[0-9-]{6}', '', 
                                    file_path_sans_ext(chirps_file)),
            start_date_text, '-', end_date_text, '_', this_country$ISO3)

        chirps <- stack(chirps_file, bands=band_nums)

        this_chirps <- crop(chirps, this_country)
        this_chirps <- mask(this_chirps, this_country)

        # Function to calculate trend
        calc_decadal_trend <- function(p, dates, inc_subyrs, ...) {
            p[p == -9999] <- NA
            # Setup period identifiers so the data can be used in a dataframe
            years <- year(dates)
            years_rep <- rep(years, each=dim(p)[1]*dim(p)[2])
            subyrs <- rep(seq(min(inc_subyrs), max(inc_subyrs)),
                          length.out=dim(p)[3])
            subyrs_rep <- rep(subyrs, each=dim(p)[1]*dim(p)[2])
            pixels_rep <- rep(seq(1:(dim(p)[1]*dim(p)[2])), dim(p)[3])
            p_df <- data.frame(year=years_rep,
                               subyear=subyrs_rep, 
                               pixel=pixels_rep,
                               ppt=as.vector(p))
            if (!is.na(inc_subyrs)) {
                p_df <- dplyr::filter(p_df, subyear %in% inc_subyrs)
            }
            # Map areas that are getting signif. wetter or drier, coded by mm per 
            # year
            extract_coefs <- function(indata) {
                if (sum(!is.na(indata$ppt_annual_pctmean)) < 3) {
                    d <- data.frame(coef=c('(Intercept)', 'year'), c(NA, NA), c(NA, NA))
                } else {
                    model <- lm(ppt_annual_pctmean ~ year, data=indata)
                    d <- data.frame(summary(model)$coefficients[, c(1, 4)])
                    d <- cbind(row.names(d), d)
                }
                names(d) <- c('coef', 'estimate', 'p_val')
                row.names(d) <- NULL
                return(d)
            }
            lm_coefs <- group_by(p_df, year, pixel) %>%
                summarize(ppt_annual=sum(ppt, na.rm=TRUE)) %>%
                group_by(pixel) %>%
                mutate(ppt_annual_pctmean=(ppt_annual/mean(ppt_annual))*100) %>%
                do(extract_coefs(.))
            # Note the *10 below to convert to decadal change
            out <- array(c(filter(lm_coefs, coef == "year")$estimate * 10,
                           filter(lm_coefs, coef == "year")$p_val),
                         dim=c(dim(p)[1], dim(p)[2], 2))
            # Mask out nodata areas
            out[ , , 1][is.na(p[ , , 1])] <- NA
            out[ , , 2][is.na(p[ , , 1])] <- NA
            out
        }

        decadal_trend <- rasterEngine(p=this_chirps,
            args=list(dates=dates, inc_subyrs=inc_subyrs),
            fun=calc_decadal_trend, datatype='FLT4S', outbands=2, outfiles=1, 
            processing_unit="chunk",
            filename=paste0(out_basename, '_trend_decadal', season_string),
            .packages=c('dplyr', 'lubridate'))
        writeRaster(decadal_trend,
                    filename=paste0(out_basename, '_trend_decadal', season_string, '_geotiff.tif'),
                    overwrite=TRUE)
    }
}

stopCluster(cl)