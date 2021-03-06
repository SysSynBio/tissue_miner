#!/usr/bin/env Rscript

argv = commandArgs(TRUE)
if(length(argv) != 1){
    stop("Usage: CalculateShearContributions.R  <movie_db_directory>")
}else{
    movieDir=normalizePath(argv[1])
    if(is.na(file.info(movieDir)$isdir)) stop(paste("movie directory does not exist"))
}

# movieDir=getwd()

########################################################################################################################
### Setup environment

db_name=basename(movieDir)

scriptsDir=Sys.getenv("TM_HOME")

if(is.na(file.info(scriptsDir)$isdir)){
    stop(paste("TM_HOME  not correctly defined (",scriptsDir ,")"))
}

source(file.path(scriptsDir, "commons/TMCommons.R"))
source(file.path(scriptsDir, "shear/ShearFunctions.R"))

require.auto("png")

db <- openMovieDb(movieDir)

shearContribDir <- file.path(movieDir, "shear_contrib")
mcdir(shearContribDir)


########################################################################################################################
##### Calculate Individual Shear Components:  t --deformation--> I2 --T1--> I2 --CD--> t+dt

## note: we use new.env() for better memory management
source(file.path(scriptsDir, "shear/CreateIntermediates.R"), local=new.env())



########################################################################################################################
### Load data required for both roi-based and roi-free analysis

# triangles <- local(get(load("triangles.RData")))
triList <- local(get(load("triList.RData")))
triWithFrame <- subset(with(triList, data.frame(frame, tri_id)), !duplicated(tri_id))

cells <- dbGetQuery(db, "select frame, cell_id, center_x, center_y, area from cells where cell_id!=10000")

simpleTri <- dt.merge(triList, cells, by=c("frame", "cell_id"), all.x=T)
rm(triList)

########################################################################################################################
#### Apply model for different rois

roiBT <- with(local(get(load("../roi_bt/lgRoiSmoothed.RData"))), data.frame(cell_id, roi))

## add roi that includes all cells at all frames
## todo seems to cause problems for PA_Sample_correction
roiBT <- rbind(roiBT, data.frame(cell_id=unique(cells$cell_id), roi="raw"))

# with(roiBT, as.data.frame(table(roi)))

# condense some rois
#roiBT <- transform(roiBT, roi=ifelse(str_detect(roi, "interL|InterL|postL5"), "intervein", ifelse(str_detect(roi, "^L[0-9]{1}$"), "vein", ac(roi))))

if(F){ #### DEBUG
cellshapes <- local(get(load(file.path(movieDir, "cellshapes.RData"))))
dt.merge(cellshapes, roiBT, by="cell_id", allow.cartesian=T) %>%
    filter(roi!="blade") %>% render_frame(20)+ geom_polygon(aes(x_pos, y_pos, fill=roi, group=cell_id),  alpha=0.5)
} #### DEBUG end


print("Assigning rois to triangulation...")

## old data.table impl
#assignROI <- function(triData, roiDef){
#  ## cartesion is necessary here, because cells can belong to multiple rois
#  triDataRoi <- dt.merge(triData, fac2char(roiDef), by=c("cell_id"), allow.cartesian=TRUE)
#  triDataRoi <- as.df(data.table(triDataRoi)[, is_valid:=length(cell_id)==3, by=c("tri_id", "roi")])
#  return(subset(triDataRoi, is_valid, select=-is_valid))
#}

assignROI <- function(triData, roiDef){
   ## we merge by cell_id, not by frame, then ROI are also assigned to fake cell_id in intermediates
   inner_join(triData, roiDef, by="cell_id") %>%
#        data.table() %>%
        group_by(tri_id, roi) %>%
        filter(n()==3) %>%
        ungroup()
}

chunkByRoi <- function(triDataRoi,roiName, dir, fileprefix){ # for memory managment during parallelization
  l_ply(roiName, function(curROI){
    gc()
    triDataRoiSlim <- filter(triDataRoi, roi==curROI) %>% as.df()
    save(triDataRoiSlim, file=file.path(dir, paste0(fileprefix,"_",curROI,".RData")), compression_level=1)
  }, .parallel=T, .inform=T)
}

# Define temp directory for chunked data
#tmpDir <- tempdir()
tmpDir <- file.path(getwd(),".shear_chunks")
dir.create(tmpDir)

simpleTriRoi <- assignROI(simpleTri,roiBT)
shearRois <- unique(simpleTriRoi$roi) %>% ac
chunkByRoi(simpleTriRoi,shearRois,tmpDir,"simpleTriRoi"); rm(simpleTriRoi)

firstIntRoi <- assignROI(local(get(load("firstInt.RData"))),roiBT)
chunkByRoi(firstIntRoi,shearRois,tmpDir,"firstIntRoi"); rm(firstIntRoi)

sndIntRoi <- assignROI(local(get(load("sndInt.RData"))),roiBT)
chunkByRoi(sndIntRoi,shearRois,tmpDir,"sndIntRoi"); rm(sndIntRoi)

if(F){
zeroIntRoi <- assignROI(local(get(load("zeroInt.RData"))),roiBT)
chunkByRoi(zeroIntRoi,shearRois,tmpDir,"zeroIntRoi"); rm(zeroIntRoi)
}

thirdIntRoi <- assignROI(local(get(load("thirdInt.RData"))),roiBT)
chunkByRoi(thirdIntRoi,shearRois,tmpDir,"thirdIntRoi"); rm(thirdIntRoi)

rm(cells, roiBT, simpleTri)

####################################################################################################
print("Calculating shear contributions...")
options(device="png") ## disable interactive graphics for parallel roi processing

#detach("package:dplyr", unload=TRUE)
#library("dplyr", lib.loc="~/R/x86_64-pc-linux-gnu-library/3.1")
#
#detach("package:data.table", unload=TRUE)
#library("data.table", lib.loc="~/R/x86_64-pc-linux-gnu-library/3.1")


l_ply(shearRois, function(curROI){
    gc()

    #DEBUG curROI="blade"
    simpleTri <- subset(local(get(load(file.path(tmpDir, paste0("simpleTriRoi_",curROI,".RData"))))), select=-roi)
    firstInt <- subset(local(get(load(file.path(tmpDir, paste0("firstIntRoi_",curROI,".RData"))))), select=-roi)
    sndInt <- subset(local(get(load(file.path(tmpDir, paste0("sndIntRoi_",curROI,".RData"))))), select=-roi)
    if(F){
      zeroInt <- subset(local(get(load(file.path(tmpDir, paste0("zeroIntRoi_",curROI,".RData"))))), select=-roi)
    }
    thirdInt <- subset(local(get(load(file.path(tmpDir, paste0("thirdIntRoi_",curROI,".RData"))))), select=-roi)

    mcdir(file.path(shearContribDir, curROI))

    echo("calculating shear contributions for ", curROI, "...")
    source(file.path(scriptsDir, "shear/ShearByCellEvents2.R"), local=new.env())
}, .parallel=F, .inform=T)

