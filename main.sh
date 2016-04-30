#!/bin/sh

## construction of the basic diretory structure
git clone https://github.com/drtamermansour/horse_trans.git
cd horse_trans
horse_trans=$(pwd)
mkdir -p $horse_trans/{resources,prepdata,tissue_merge,refGenome,public_assemblies} ## you should have 2 folders already (scripts&track_hub) by cloning the original repository.  

## read the user configurations
source $horse_trans/user_config.txt
cat $horse_trans/user_config.txt

## create a config file to contain all the pathes to be used by all pipelines
> $horse_trans/config.txt
echo "script_path=$horse_trans/scripts" >> $horse_trans/config.txt
echo "resources=$horse_trans/resources" >> $horse_trans/config.txt
echo "prepData=$horse_trans/prepdata" >> $horse_trans/config.txt
echo "extData=$horse_trans/extdata" >> $horse_trans/config.txt
echo "tissue_merge=$horse_trans/tissue_merge" >> $horse_trans/config.txt
echo "genome_dir=$horse_trans/refGenome" >> $horse_trans/config.txt
echo "pubAssemblies=$horse_trans/public_assemblies" >> $horse_trans/config.txt
echo "track_hub=$horse_trans/track_hub" >> $horse_trans/config.txt
source $horse_trans/config.txt

## UCSC kent commands are used a lot through out the pipeline.
## http://genome-source.cse.ucsc.edu/gitweb/?p=kent.git;a=blob;f=src/userApps/README
## http://hgdownload.cse.ucsc.edu/admin/exe/linux.x86_64/FOOTER
## wget -r --no-directories ftp://hgdownload.cse.ucsc.edu/admin/exe/linux.x86_64/

###########################################################################################
#### prepare the raw fastq files:
## Every tissue has a separate folder carrying its name (maximum 14 letter) in $prepData.
## Every RNAseq libarary should have a separate folder into the corresponding tissue folder.
## The libarary folder name should start with PE_ or SE_ according to the sequencoing type
## Then it should should have the read length followed by underscore
## Then it should have fr.unstranded_ , fr.firststrand_ , fr.secondstrand_ according to lib type
## Then the owner name (or names separted by dots) followed by underscore
## Then the date of sequencing as MMDDYYYY
## The raw data files should be kept in a folder named fastq_data in the libarary folder
## The raw data files should be prepared so that they have enconding "Sanger / illumina 1.9"
## The file names should fit the format *_R1_*.fastq.gz & *_R2_*.fastq.gz for PE reads or *_SR_*.fastq.gz for SE
## All reads in every given file should belong to ONE sequencing lane.
## If there are sample replicates from different lanes, you can add a text file called "replicates.txt"
## A line in this file should have the names of one sample replicates with space separation. (only the *_R1_*.fastq.gz for PE reads or *_SR_*.fastq.gz for SE)
## The first syllbus (the part of the file name before _R1_ , _R2_ or _SR_) should be unique

## a representive work out to one SRA reposatories
newLib=$"PBMCs/PE_49_fr.unstranded_bioproj.265983_10302014"
SRA_URL=$"ftp-trace.ncbi.nlm.nih.gov/sra/sra-instant/reads/ByRun/sra/ERR/ERR653"
mkdir -p $rawData/$newLib
cd $rawData/PBMCs/PE_49_fr.unstranded_bioproj.265983_10302014
bash $script_path/prep_proj.sh $SRA_URL $extData $script_path ## the script assume no sample replicates
###########################################################################################
## define the list of working directory and the list samples in each. This is where you can edit the output list file(s) to restrict the processing for certain target(s)
rm -f $horse_trans/working_list.txt
for work_dir in $prepData/*/{PE_*,SE_*}; do if [ -d $work_dir/fastq_data ]; then
  echo $work_dir >> $horse_trans/working_list.txt
  rm -f $work_dir/fastq_data/sample_list.txt
  for f in $work_dir/fastq_data/{*_R1_*.fastq.gz,*_SR_*.fastq.gz}; do if [ -f $f ]; then
    echo $f >> $work_dir/fastq_data/sample_list.txt; fi; done;
fi; done;

## get read length statistics
headers=$(Rscript -e 'cat("Tissue", "Library", "No_of_samples", "No_of_reads(M)", "Total_bp_count(Gb)", "Min_length", "Max_length", "Median_length", "Mean_length", sep="\t");')
echo "$headers" > $horse_trans/raw_statistics.txt
while read work_dir; do
  echo $work_dir
  cd $work_dir/fastq_data
  sample_list=$work_dir/fastq_data/sample_list.txt
  cat sample_list.txt | xargs zcat | awk '{if(NR%4==2) print length($1)}' > input.readslength.txt
  stat=$(Rscript -e 'd<-scan("input.readslength.txt", quiet=TRUE); cat(round(length(d)/10^6,2), round(sum(d)/10^9,2), min(d), max(d), median(d), mean(d), sep="\t");')
  lib=$(basename $work_dir)
  tissue=$(dirname $work_dir | xargs basename)
  no=$(cat $sample_list | wc -l)
  echo "$tissue"$'\t'"$lib"$'\t'"$no"$'\t'"$stat" >> $horse_trans/raw_statistics.txt
done < $horse_trans/working_list.txt

## prepare sorted working list according to read length
tail -n+2 $horse_trans/raw_statistics.txt | sort -k8,8nr | awk -v myRoot=$prepData '{ print myRoot"/"$1"/"$2 }' > $horse_trans/working_list_sorted.txt
###########################################################################################
## prepare list of external data 
rm -f $horse_trans/extdata_list.txt
for work_dir in $extData/*/{PE_*,SE_*}; do if [ -d $work_dir/fastq_data ]; then
  echo $work_dir >> $horse_trans/extdata_list.txt
  rm -f $work_dir/fastq_data/sample_list.txt
  for f in $work_dir/fastq_data/{*_R1_*.fastq.gz,*_SR_*.fastq.gz}; do if [ -f $f ]; then
    echo $f >> $work_dir/fastq_data/sample_list.txt; fi; done;
fi; done;
###########################################################################################
#### Read trimming
## This step requires input working_list & sample_list and output folder
## the module should produce trimmed reads in the form of (*_R1_*.pe.se.fq and *_R2_*.pe.fq) for PE lib and (*_SR_*.se.fq) for SE
## The output is an sample list with *_R1_*.pe.se.fq and *_SR_*.se.fq files

## Mild trimming with Trimmomatic using sliding window
while read work_dir; do
  echo $work_dir
  mkdir -p $work_dir/trimmed_RNA_reads
  cd $work_dir/trimmed_RNA_reads
  lib=$(basename $work_dir | cut -d"_" -f 1)                   ## PE or SE
  sample_list=$work_dir/fastq_data/sample_list.txt
  bash ${script_path}/run_adapter_trimmer.sh $sample_list $lib $platform  
done < $horse_trans/working_list.txt

## Check for successful trimming and trouble shooting the failed trimming jobs (requires T_Trim.e)
while read work_dir; do
  cd $work_dir/trimmed_RNA_reads
  sample_list=$work_dir/fastq_data/failedSamples.txt           ## define the path of empty file
  bash $script_path/check_ad_trim.sh "$sample_list"
  x=$(cat $sample_list | wc -l)
  if [ $x -ne 0 ]; then
    lib=$(basename $work_dir | cut -d"_" -f 1)
    echo "Failed jobs in: "$work_dir
    bash ${script_path}/run_adapter_trimmer.sh $sample_list $lib $platform
  fi
done < $horse_trans/working_list.txt

#### merge singletones
while read work_dir; do if [ -d $work_dir/trimmed_RNA_reads ]; then
  cd $work_dir/trimmed_RNA_reads
  ## change /2 to /1 in s2_se then combine single reads
  for f in $work_dir/trimmed_RNA_reads/*_R1_*.se.fq; do if [ -f $f ]; then echo $f; f2=$(basename $f | sed 's/_R1_/_R2_/'); newf=$(basename $f | sed 's/_R1_/_R_/'); sed 's/\/2$/\/1/g' $f2 > $f2.temp; cat $f $f2.temp > $newf; fi; done;
  rm -f *.se.fq.temp
  ## merge the single reads to the end of s1_pe file to make s1_pe_se
  for f in $work_dir/trimmed_RNA_reads/*_R1_*.pe.fq; do if [ -f $f ]; then echo $f; fr=$(basename $f | sed 's/_R1_/_R_/'); fr2=$(echo $fr | sed 's/.pe.fq/.se.fq/'); newf=$(basename $f | sed 's/.pe.fq/.pe.se.fq/'); cat $f $fr2 > $newf; fi; done;
  #rm {*_R1_*.pe.fq,*.se.fq}   ## all what you need *_R1_*.pe.se.fq and *_R2_*.pe.fq
fi
done < $horse_trans/working_list.txt

## define the list samples for subsequent analysis
## This is where you can edit the output list file(s) to restrict the processing for certain target(s)
while read work_dir; do if [ -d $work_dir/trimmed_RNA_reads ]; then
  rm -f $work_dir/trimmed_RNA_reads/sample_list.txt
  for f in $work_dir/trimmed_RNA_reads/{*_R1_*.pe.se.fq,*_SR_*.se.fq}; do if [ -f $f ]; then
    echo $f >> $work_dir/trimmed_RNA_reads/sample_list.txt; fi; done;
fi; done < $horse_trans/working_list.txt

###########################################################################################
## Assess read length statistics after trimming
headers=$(Rscript -e 'cat("Tissue", "Library", "No_of_samples", "No_of_reads(M)", "Total_bp_count(Gb)", "Min_length", "Max_length", "Median_length", "Mean_length", sep="\t");')
echo "$headers" > $horse_trans/trimmed_statistics.txt
while read work_dir; do
  echo $work_dir
  cd $work_dir/trimmed_RNA_reads
  sample_list=$work_dir/trimmed_RNA_reads/sample_list.txt
  lib=$(basename $work_dir)
  tissue=$(dirname $work_dir | xargs basename)
  no=$(cat $sample_list | wc -l)
  libType=$(basename $work_dir | cut -d"_" -f 1)                      ## PE or SE
  if [ "$libType" = $"PE" ]; then
    ## stats of the R1 files
    cat sample_list.txt | sed 's/.pe.se.fq/.pe.fq/'| xargs cat | awk '{if(NR%4==2) print length($1)}' > trimmed_R1.readslength.txt
    stat=$(Rscript -e 'd<-scan("trimmed_R1.readslength.txt", quiet=TRUE); cat(round(length(d)/10^6,2), round(sum(d)/10^9,2), min(d), max(d), median(d), mean(d), sep="\t");')
    echo "$tissue"$'\t'"$lib"$'_R1\t'"$no"$'\t'"$stat" >> $horse_trans/trimmed_statistics.txt

    ## stats of the R2 files
    cat sample_list.txt | sed 's/\(.*\)_R1_\(.*\).pe.se.fq/\1_R2_\2.pe.fq/'| xargs cat | awk '{if(NR%4==2) print length($1)}' > trimmed_R2.readslength.txt
    stat=$(Rscript -e 'd<-scan("trimmed_R2.readslength.txt", quiet=TRUE); cat(round(length(d)/10^6,2), round(sum(d)/10^9,2), min(d), max(d), median(d), mean(d), sep="\t");')
    echo "$tissue"$'\t'"$lib"$'_R2\t'"$no"$'\t'"$stat" >> $horse_trans/trimmed_statistics.txt

   ## stats of the singletones files
    cat sample_list.txt | sed 's/\(.*\)_R1_\(.*\).pe.se.fq/\1_R_\2.se.fq/'| xargs cat | awk '{if(NR%4==2) print length($1)}' > trimmed_SE.readslength.txt
    stat=$(Rscript -e 'd<-scan("trimmed_SE.readslength.txt", quiet=TRUE); cat(round(length(d)/10^6,2), round(sum(d)/10^9,2), min(d), max(d), median(d), mean(d), sep="\t");')
    echo "$tissue"$'\t'"$lib"$'_SE\t'"$no"$'\t'"$stat" >> $horse_trans/trimmed_statistics.txt
  elif [ "$libType" = $"SE" ]; then
    cat sample_list.txt | xargs cat | awk '{if(NR%4==2) print length($1)}' > trimmed.readslength.txt
    stat=$(Rscript -e 'd<-scan("trimmed.readslength.txt", quiet=TRUE); cat(round(length(d)/10^6,2), round(sum(d)/10^9,2), min(d), max(d), median(d), mean(d), sep="\t");')
    echo "$tissue"$'\t'"$lib"$'\t'"$no"$'\t'"$stat" >> $horse_trans/trimmed_statistics.txt
fi; done < $horse_trans/working_list.txt
###########################################################################################
## get the referenece genome
cd $genome_dir
wget --timestamping 'ftp://hgdownload.cse.ucsc.edu/goldenPath/equCab2/bigZips/chromFa.tar.gz' -O chromFa.tar.gz
tar xvzf chromFa.tar.gz

## prepare Bowtie2Index (for Tophat mapping)
mkdir -p $genome_dir/Bowtie2Index && cd $genome_dir/Bowtie2Index
cat ../*.fa > genome.fa
bash ${script_path}/run_bowtie2-build.sh genome.fa genome $platform
echo "genome=$genome_dir/Bowtie2Index/genome.fa" >> $horse_trans/config.txt
echo "Bowtie2_genome_index_base=$genome_dir/Bowtie2Index/genome" >> $horse_trans/config.txt
source $horse_trans/config.txt

## prepare BWA index (for GATK variant analysis)
mkdir -p $genome_dir/BwaIndex && cd $genome_dir/BwaIndex
cat ../*.fa > genome.fa
bash ${script_path}/run_bwa-index.sh genome.fa
echo "Bwa_ref=$genome_dir/BwaIndex/genome.fa" >> $horse_trans/config.txt
source $horse_trans/config.txt

## prepare GATK dictionary and index (for GATK variant analysis)
mkdir -p $genome_dir/gatkIndex && cd $genome_dir/gatkIndex
cat ../*.fa > genome.fa
bash ${script_path}/run_gatk-index.sh genome.fa
echo "gatk_ref=$genome_dir/gatkIndex/genome.fa" >> $horse_trans/config.txt
echo "gatk_ref_index=$genome_dir/gatkIndex/genome.fa.fai" >> $horse_trans/config.txt
echo "gatk_ref_dict=$genome_dir/gatkIndex/genome.dict" >> $horse_trans/config.txt
source $horse_trans/config.txt
###########################################################################################
## map the genomes: create liftover files to allow mapping of NCBI annotation to UCSC tracks 
## http://genomewiki.ucsc.edu/index.php/LiftOver_Howto
bash $script_path/mapGenome.sh $genome          ## ends by creating ncbi/NCBItoUCSC_map.sorted.chain

###########################################################################################
## Create GTF file for refGenes track of UCSC
## generation of GTF from UCSC tables using the guidelines of genomewiki.ucsc
## http://genomewiki.ucsc.edu/index.php/Genes_in_gtf_or_gff_format
## The commands of wikigenome are modified to match the table schemes
## Note: using genepredToGTF can resolve duplicates of transcript ids but not for gene ids so the 10 fields genepred format which uses transcript names as gene names produce no duplicates but the extended genepred uses separte gene names from column 12 and susceptible for gene name duplication
cd $genome_dir
wget http://hgdownload.cse.ucsc.edu/goldenPath/equCab2/database/refGene.txt.gz
ucscTable=$"refGene.txt.gz"
output_GTF=$"refGene.gtf"
#bash ${script_path}/ucscTableToGTF.sh $ucscTable $output_GTF
zcat $ucscTable | cut -f2-16 | $script_path/UCSC_kent_commands/genePredToGtf file stdin $output_GTF
echo "refGTF_file=$genome_dir/refGene.gtf" >> $horse_trans/config.txt
output_GTF=$"refGene_transcripts.gtf"
#bash ${script_path}/ucscTableToGTF2.sh $ucscTable $output_GTF
zcat $ucscTable | cut -f2-11 | $script_path/UCSC_kent_commands/genePredToGtf file stdin $output_GTF
echo "refTransGTF_file=$genome_dir/refGene_transcripts.gtf" >> $horse_trans/config.txt
zcat $ucscTable | cut -f2-16 | $script_path/genePredToBed > refGene.bed
echo "refBED_file=$genome_dir/refGene.bed" >> $horse_trans/config.txt
source $horse_trans/config.txt

## Get the NCBI annotation files
wget ftp://ftp.ncbi.nih.gov/genomes/Equus_caballus/GFF/ref_EquCab2.0_top_level.gff3.gz
gunzip ref_EquCab2.0_top_level.gff3.gz
sed 's/28908588/28908590/' ref_EquCab2.0_top_level.gff3 > ref_EquCab2.0_top_level_edit.gff3
$script_path/UCSC_kent_commands/gff3ToGenePred -useName ref_EquCab2.0_top_level_edit.gff3 ref_EquCab2.0_top_level.gpred
## exclude non RNA entries e.g. CDs with no parant transcripts, gene_segments, ..
egrep "^rna|^NM|^NR|^XM|^XR" ref_EquCab2.0_top_level.gpred > ref_EquCab2.0_top_level_rna.gpred
$script_path/UCSC_kent_commands/liftOver ref_EquCab2.0_top_level_rna.gpred $genome_dir/ncbi/NCBItoUCSC_map.sorted.chain ref_EquCab2.0_top_level_mapped_rna.gpred unMapped -genePred
$script_path/UCSC_kent_commands/genePredToGtf file ref_EquCab2.0_top_level_mapped_rna.gpred ref_EquCab2.0_top_level_rna.gtf
echo "ncbiGTF_file=$genome_dir/ref_EquCab2.0_top_level_rna.gtf" >> $horse_trans/config.txt
cat ref_EquCab2.0_top_level_mapped_rna.gpred | $script_path/genePredToBed > ref_EquCab2.0_top_level_mapped_rna.bed
echo "ncbiBED_file=$genome_dir/ref_EquCab2.0_top_level_mapped_rna.bed" >> $horse_trans/config.txt

$script_path/UCSC_kent_commands/gff3ToGenePred ref_EquCab2.0_top_level_edit.gff3 ref_EquCab2.0_top_level_noName.gpred
## exclude non RNA entries e.g. CDs with no parant transcripts, gene_segments, ..
grep "^rna" ref_EquCab2.0_top_level_noName.gpred > ref_EquCab2.0_top_level_noName_rna.gpred
$script_path/UCSC_kent_commands/liftOver ref_EquCab2.0_top_level_noName_rna.gpred ncbi/NCBItoUCSC_map.sorted.chain ref_EquCab2.0_top_level_mapped_noName_rna.gpred unMapped_noName -genePred
$script_path/UCSC_kent_commands/genePredToGtf file ref_EquCab2.0_top_level_mapped_noName_rna.gpred ref_EquCab2.0_top_level_noName_rna.gtf
echo "ncbiNoNameGTF_file=$genome_dir/ref_EquCab2.0_top_level_noName_rna.gtf" >> $horse_trans/config.txt
cat ref_EquCab2.0_top_level_mapped_noName_rna.gpred | $script_path/genePredToBed > ref_EquCab2.0_top_level_mapped_noName_rna.bed
echo "ncbiNoNameBED_file=$genome_dir/ref_EquCab2.0_top_level_mapped_noName_rna.bed" >> $horse_trans/config.txt
source $horse_trans/config.txt

## Get the ensemble GTF files
wget http://hgdownload.cse.ucsc.edu/goldenPath/equCab2/database/ensGene.txt.gz
ucscTable=$"ensGene.txt.gz"
output_GTF=$"ensGene.gtf"
#bash ${script_path}/ucscTableToGTF.sh $ucscTable $output_GTF
zcat $ucscTable | cut -f2-16 | $script_path/UCSC_kent_commands/genePredToGtf file stdin $output_GTF
echo "ensGTF_file=$genome_dir/ensGene.gtf" >> $horse_trans/config.txt
zcat $ucscTable | cut -f2-16 | $script_path/genePredToBed > ensGene.bed
echo "ensBED_file=$genome_dir/ensGene.bed" >> $horse_trans/config.txt
source $horse_trans/config.txt
#wget ftp://ftp.ensembl.org/pub/release-80/gtf/equus_caballus/Equus_caballus.EquCab2.80.gtf.gz
#gunzip Equus_caballus.EquCab2.80.gtf.gz
#echo "ensGTF_file=$genome_dir/Equus_caballus.EquCab2.80.gtf" >> $horse_trans/config.txt
#source $horse_trans/config.txt
###########################################################################################
## get known variants
mkdir $genome_dir/knowVar
cd $genome_dir/knowVar
wget --timestamping 'ftp://ftp.ensembl.org/pub/release-82/variation/vcf/equus_caballus/Equus_caballus.vcf.gz' -O Equus_caballus.vcf.gz
wget --timestamping 'ftp://ftp.ensembl.org/pub/release-82/variation/vcf/equus_caballus/Equus_caballus_structural_variations.vcf.gz' -O Equus_caballus_structural_variations.vcf.gz
wget --timestamping 'ftp://ftp.ensembl.org/pub/release-82/variation/vcf/equus_caballus/Equus_caballus_incl_consequences.vcf.gz' -O Equus_caballus_incl_consequences.vcf.gz
gunzip *.gz

## change the name of the chromosomes to match the UCSC genome (bet keep the file co-ordinates 1-based)
grep -v "^#" Equus_caballus_structural_variations.vcf | awk -F "\t" -v OFS='\t' '{ print "chr"$1,$2,$3,$4,$5,$6,$7,$8 }' > Equus_caballus_structural_variations_fixedChrNames.vcf
sed -i 's/chrMT/chrM/g' Equus_caballus_structural_variations_fixedChrNames.vcf
perl $script_path/sortByRef.pl Equus_caballus_structural_variations_fixedChrNames.vcf $gatk_ref_index > Equus_caballus_structural_variations_fixedChrNames_sorted.vcf
grep "^#" Equus_caballus_structural_variations.vcf > Equus_caballus_structural_variations_final.vcf
cat Equus_caballus_structural_variations_fixedChrNames_sorted.vcf >> Equus_caballus_structural_variations_final.vcf
echo "knownIndels=$genome_dir/knowVar/Equus_caballus_structural_variations_final.vcf" >> $horse_trans/config.txt
grep -v "^#" Equus_caballus.vcf | awk -F "\t" -v OFS='\t' '{ print "chr"$1,$2,$3,$4,$5,$6,$7,$8 }' > Equus_caballus_fixedChrNames.vcf
sed -i 's/chrMT/chrM/g' Equus_caballus_fixedChrNames.vcf
perl $script_path/sortByRef.pl Equus_caballus_fixedChrNames.vcf $gatk_ref_index > Equus_caballus_fixedChrNames_sorted.vcf
grep "^#" Equus_caballus.vcf > Equus_caballus_final.vcf
#cat Equus_caballus_fixedChrNames_sorted.vcf >> Equus_caballus_final.vcf
grep "TSA=SNV" Equus_caballus_fixedChrNames_sorted.vcf >> Equus_caballus_final.vcf
echo "knownSNPs=$genome_dir/knowVar/Equus_caballus_final.vcf" >> $horse_trans/config.txt
source $horse_trans/config.txt
###########################################################################################
### Initiate the basic structure for horse track hubs
echo "UCSCgenome=equCab2" >> $horse_trans/config.txt
echo "chromSizes=$genome_dir/$UCSCgenome.chrom.sizes" >> $horse_trans/config.txt
source $horse_trans/config.txt
## fetch the UCSC database to get the chromosome sizes
bash ${script_path}/calcChromSizes.sh $UCSCgenome $chromSizes
## Create the basic directory structure of the track hubs
mkdir -p $track_hub/$UCSCgenome/BigBed
###########################################################################################
## Track for public assemblies
mkdir -p $pubAssemblies/Hestand_2014 && cd $pubAssemblies/Hestand_2014
wget http://server1.intrepidbio.com/FeatureBrowser/gtffilereader/record/-4027466309079733025/7666675698.gtf

mkdir -p $pubAssemblies/NCBI && cd $pubAssemblies/NCBI
cp $ncbiGTF_file ncbiAnn.gtf

mkdir -p $pubAssemblies/ISME.PBMC && cd $pubAssemblies/ISME.PBMC
wget http://europepmc.org/articles/PMC4366165/bin/pone.0122011.s005.zip
unzip *.zip

## create list of public assemblies
rm -f $pubAssemblies/public_assemblies.txt
for tissue in $pubAssemblies/*; do
  echo "$pubAssemblies" "${tissue#$pubAssemblies/}" >> $pubAssemblies/public_assemblies.txt;
done
####################
## convert the gtf files into BigBed files & copy the BigBed files to the track hub directory
update=0    ## 0 means do not update Bigbed files & 1 means update
rm -f $horse_trans/public_assemblies.txt
while read ass_path assembly; do
  echo $assembly
  cd $ass_path/$assembly
  if [[ ! -f "*.BigBed" || "$update" -eq 1 ]];then
    targetAss=$(ls *.gtf)
    if [ -f "$targetAss" ];then
      bash $script_path/gtfToBigBed.sh "$targetAss" "$genome_dir/$UCSCgenome.chrom.sizes" "$script_path"
    else echo "can not find target assembly"; break;fi
    if [ -f ${targetAss%.bed}.BigBed ];then
      identifier=$(echo $assembly | sed 's/\//_/g' | sed 's/_output//g')
      cp ${targetAss%.bed}.BigBed $track_hub/$UCSCgenome/BigBed/${identifier}.BigBed
    else echo "could not make merged.BigBed file"; break; fi
  fi
  echo $ass_path/$assembly >> $horse_trans/public_assemblies.txt;
done < $pubAssemblies/public_assemblies.txt

## initiate a given track hub
hub_name=$"HorseTrans_public_assemblies"
shortlabel=$"public_assemblies"
longlabel=$"Publically available assemblies"
email=$"drtamermansour@gmail.com"
cd $track_hub
bash $script_path/create_trackHub.sh "$UCSCgenome" "$hub_name" "$shortlabel" "$longlabel" "$email"

## edit the trackDb
current_libs=$track_hub/current_libs_$shortlabel
current_tissues=$track_hub/current_tiss_$shortlabel
trackDb=$track_hub/$UCSCgenome/trackDb_$shortlabel.txt
lib_assemblies=$pubAssemblies/public_assemblies.txt
tiss_assemblies=$horse_trans/emptyTemp.txt
bash $script_path/edit_trackDb.sh $current_libs $current_tissues $trackDb $lib_assemblies $tiss_assemblies
###########################################################################################
### Install homology search databases
## download protein database such as Swissprot (fast) or Uniref90 (slow but more comprehensive)
mkdir -p $genome_dir/ptnDB
cd $genome_dir/ptnDB
wget ftp://ftp.uniprot.org/pub/databases/uniprot/current_release/knowledgebase/complete/uniprot_sprot.fasta.gz
gunzip uniprot_sprot.fasta.gz
#wget ftp://ftp.uniprot.org/pub/databases/uniprot/uniref/uniref90/uniref90.fasta.gz
#gunzip uniref90.fasta.gz
echo "refPtn=$genome_dir/ptnDB/uniprot_sprot.fasta" >> $horse_trans/config.txt
#echo "refPtn=$genome_dir/ptnDB/uniref90.fasta" >> $horse_trans/config.txt
source $horse_trans/config.txt
bash $script_path/make_ptnDB.sh $refPtn
#bash $script_path/make_ptnDB.sh $refPtn

## download pfam database
wget ftp://ftp.broadinstitute.org/pub/Trinity/Trinotate_v2.0_RESOURCES/Pfam-A.hmm.gz
gunzip Pfam-A.hmm.gz
echo "refPfam=$genome_dir/ptnDB/Pfam-A.hmm" >> $horse_trans/config.txt
source $horse_trans/config.txt
bash $script_path/make_PfamDB.sh $refPfam
###########################################################################################
## build Tophat transcriptome-index
echo "transcriptome_index=$genome_dir/trans_index/equ" >> $horse_trans/config.txt
source $horse_trans/config.txt
bash ${script_path}/run_buildTransIndex.sh "$refGTF_file" "$transcriptome_index" "$Bowtie2_genome_index_base" "$platform"
###########################################################################################
#### Mapping
## This step requires input  working_list & sample_list and output folder
## the module should produce mapped reads in the form of tophat_<sampleID>/accepted.bam
## The output is an sample list with accepted.bam files

## refGene guided Tophat mapping per sample
while read work_dir; do
  echo $work_dir
  mkdir -p $work_dir/tophat_output
  cd $work_dir/tophat_output
  lib=$(basename $work_dir | cut -d"_" -f 1)                      ## PE or SE
  strand=$(basename $work_dir | cut -d"_" -f 3 | sed 's/\./-/')   ## fr-unstranded, fr-firststrand or fr-secondstrand
  sample_list=$work_dir/trimmed_RNA_reads/sample_list.txt
  bash ${script_path}/run_tophat.sh "$sample_list" "$lib" "$strand" "$Bowtie2_genome_index_base" "$transcriptome_index" "$script_path"   ## Tophat sort by coordinate
done < $horse_trans/working_list.txt

## Check for successful tophat runs and trouble shooting the failed tophat jobs
while read work_dir; do
  cd $work_dir/tophat_output
  sample_list=$work_dir/trimmed_RNA_reads/sample_list.txt
  failedSample_list=$work_dir/trimmed_RNA_reads/tophat_failedSamples.txt
  > $failedSample_list                                        ## erase previouslly failed samples if any
  ##bash $script_path/check_tophat.sh "$failedSample_list"    ## require tophat-[SP]E.e & .o
  bash $script_path/check2_tophat.sh "$sample_list" "$failedSample_list"   ## check output log files
  x=$(cat $failedSample_list | wc -l)
  if [ $x -ne 0 ]; then
    lib=$(basename $work_dir | cut -d"_" -f 1)
    strand=$(basename $work_dir | cut -d"_" -f 3 | sed 's/\./-/')
    echo "Failed tophat jobs in: "$work_dir
    bash ${script_path}/run_tophat.sh "$failedSample_list" "$lib" "$strand" "$Bowtie2_genome_index_base" "$transcriptome_index" "$script_path"
  fi
done < $horse_trans/working_list.txt
##################
## create summary for tophat run
headers=$(Rscript -e 'cat("Tissue", "Library", "min_mapping", "max_mapping", "min_concordance", "max_concordance", sep="\t");')
echo "$headers" > $horse_trans/tophat_summary.txt
while read work_dir; do
  > $work_dir/tophat_output/allsample_summary.txt
  > $work_dir/tophat_output/allsample_summary_detailed.txt
  for f in $work_dir/tophat_output/tophat_*; do
    echo ${f} >> $work_dir/tophat_output/allsample_summary.txt
    cd ${f}
    grep "overall read mapping rate" align_summary.txt >> ../allsample_summary.txt
    grep "concordant pair alignment rate" align_summary.txt >> ../allsample_summary.txt
    echo ${f} >> $work_dir/tophat_output/allsample_summary_detailed.txt
    cat align_summary.txt >> ../allsample_summary_detailed.txt
  done
  mapping=$(grep "overall read mapping rate" $work_dir/tophat_output/allsample_summary.txt | awk '{ print $1 }' | sort -n | sed -e 1b -e '$!d' | tr "\n" "\t")
  conc=$(grep "concordant pair alignment rate" $work_dir/tophat_output/allsample_summary.txt | awk '{ print $1 }' | sort -n | sed -e 1b -e '$!d' | tr "\n" "\t")
  lib=$(basename $work_dir)
  tissue=$(dirname $work_dir | xargs basename)
  echo "$tissue"$'\t'"$lib"$'\t'"$mapping""$conc" >> $horse_trans/tophat_summary.txt
  cat $work_dir/tophat_output/allsample_summary_detailed.txt >> $horse_trans/tophat_summary_detailed.txt
done < $horse_trans/working_list.txt
##################
## define the list samples.
## This is where you can edit the output list file(s) to restrict the processing for certain target(s)
while read work_dir; do if [ -d $work_dir/tophat_output ]; then
  rm -f $work_dir/tophat_output/preMerge_sample_list.txt
  for f in $work_dir/tophat_output/tophat_*/accepted_hits.bam; do if [ -f $f ]; then
    echo $f >> $work_dir/tophat_output/preMerge_sample_list.txt; fi; done;
fi; done < $horse_trans/working_list.txt
###########################################################################################
## Add Read group headers
while read work_dir; do
  echo $work_dir
  lib=$(basename $work_dir)
  sample_list=$work_dir/tophat_output/preMerge_sample_list.txt
  replicates_list=$work_dir/fastq_data/replicates.txt
  bash ${script_path}/run_readGroupInfo_illumina.sh "$sample_list" "$replicates_list" "$lib" "${script_path}/readGroupInfo_illumina.sh"
done < $horse_trans/working_list.txt

## Check for successful adding of groupread
## To be added
## Tip: the line before last in .e file has "AddOrReplaceReadGroups done"
## for f in $prepData/*/*/tophat_output/tophat_*/AddOrReplaceReadGroups.e*; do grep "AddOrReplaceReadGroups done" $f | wc -l; done
###########################################################################################
## merge replicates
while read work_dir; do
  echo $work_dir
  cd $work_dir/tophat_output
  replicates_list=$work_dir/fastq_data/replicates.txt
  if [ -f $replicates_list ]; then
    bash ${script_path}/run_mergeBAM.sh "$replicates_list" "${script_path}/mergeBAM.sh" ## picard tools sort by coordinate
  else echo "No replicates file in" $work_dir;
fi; done < $horse_trans/working_list.txt

## check for successful merging
## To be added
##################
## define the list samples.
## This is where you can edit the output list file(s) to restrict the processing for certain target(s)
while read work_dir; do if [ -d $work_dir/tophat_output ]; then
  rm -f $work_dir/tophat_output/sample_list.txt
  for f in $work_dir/tophat_output/tophat_*; do if [ -d $f ]; then
    echo $f >> $work_dir/tophat_output/sample_list.txt; fi; done;
fi; done < $horse_trans/working_list.txt
###########################################################################################
#### pipeline_OneSampleAtaTime_Tophat2.Cufflinks.Cuffmerge
### Run Cufflinks: output transcripts.gtf in the same tophat_sample folder
while read work_dir; do
  echo $work_dir
  cd $work_dir/tophat_output
  sample_list=$work_dir/tophat_output/sample_list.txt
  #bash ${script_path}/run_cufflinks_wRef.sh "$sample_list" "$refGTF_file" "$script_path/cufflinks.sh";
  bash ${script_path}/run_cufflinks_noRef.sh "$sample_list" "$script_path/cufflinks_noRef.sh";
done < $horse_trans/working_list.txt

## Check for successful Cufflinks runs and trouble shooting the failed Cufflinks jobs (requires cufflinks.e)
while read work_dir; do
  cd $work_dir/tophat_output
  failedSample_list=$work_dir/tophat_output/failedSamples.txt           ## define the path of empty file
  bash $script_path/check_cufflinks.sh "$failedSample_list"
  x=$(cat $failedSample_list | wc -l)
  if [ $x -ne 0 ]; then
    echo "Failed Cufflinks jobs in: "$work_dir
    cat $failedSample_list
    #bash ${script_path}/run_cufflinks_wRef.sh "$failedSample_list" "$refGTF_file" "$script_path/cufflinks.sh";
    bash ${script_path}/run_cufflinks_noRef.sh "$failedSample_list" "$script_path/cufflinks_noRef2.sh"
fi; done < $horse_trans/working_list.txt

## downsample the failed samples to peak coverage 200x
## convert the tophat output BAM files into Fastq files
while read work_dir; do
  cd $work_dir/tophat_output
  failedSample_list=$work_dir/tophat_output/failedSamples.txt       ## define the path of empty file
  bash $script_path/check_cufflinks.sh "$failedSample_list"
  x=$(cat $failedSample_list | wc -l)
  if [ $x -ne 0 ]; then
    echo "Failed Cufflinks jobs in: "$work_dir
    cat $failedSample_list
    lib=$(basename $work_dir | cut -d"_" -f 1)
    bash ${script_path}/run_BamToFastq.sh "$failedSample_list" "$lib" "-" "$script_path/restore_mapped_trimmed.sh"
fi; done < $horse_trans/working_list.txt
## run digital normalization of lab specific tissues (need to be updated to use sample list and check for success)
kmer=20
cutoff=200
while read work_dir; do
  lib=$(basename $work_dir | cut -d"_" -f 1)
  while read data_dir; do if [ -d $data_dir ];then
    cd $data_dir
    bash ${script_path}/run_diginorm.sh "$lib" "$data_dir" "$kmer" "$cutoff" "$script_path"
  fi; done < $work_dir/tophat_output/failedSamples.txt
done < $horse_trans/working_list.txt
## split the interleaved reads
while read work_dir; do
  sample_list=$work_dir/tophat_output/failedSamples.txt
  x=$(cat $sample_list | wc -l)
  lib=$(basename $work_dir | cut -d"_" -f 1)                      ## PE or SE
  if [ $x -ne 0 ] && [ "$lib" = $"PE" ]; then
  echo $work_dir
  bash ${script_path}/run_split_reads.sh "$sample_list" $script_path/split_reads.sh
fi; done < $horse_trans/working_list.txt
## merge singletons and change the file names to fir the tophat script
while read work_dir; do
  sample_list=$work_dir/tophat_output/failedSamples.txt
  x=$(cat $sample_list | wc -l)
  lib=$(basename $work_dir | cut -d"_" -f 1)                      ## PE or SE
  if [ $x -ne 0 ] && [ "$lib" = $"PE" ]; then
    echo $work_dir
    f=$(ls *_R1_001.pe.fq)
    base=${f%_R1_001.pe.fq}
    cat $f allsingletons.fq.keep > "$base"_R1_001.pe.se.fq;
  elif [ $x -ne 0 ] && [ "$lib" = $"SE" ]; then
    mv allsingletons.fq.keep allsingletons_SR_001.se.fq
fi; done < $horse_trans/working_list.txt
## run Tophat on each sample
while read work_dir; do
  x=$(cat $work_dir/tophat_output/failedSamples.txt | wc -l)
  if [ $x -ne 0 ];then
    while read data_dir; do if [ -d $data_dir ];then
      echo $data_dir/*_R1_001.pe.se.fq
    fi; done < $work_dir/tophat_output/failedSamples.txt > $work_dir/tophat_output/failedSamples_forTophat.txt
    cat $work_dir/tophat_output/failedSamples_forTophat.txt
    mkdir -p $work_dir/tophat_output/digi_tophat_output
    cd $work_dir/tophat_output/digi_tophat_output
    lib=$(basename $work_dir | cut -d"_" -f 1)                      ## PE or SE
    strand=$(basename $work_dir | cut -d"_" -f 3 | sed 's/\./-/')   ## fr-unstranded, fr-firststrand or fr-secondstrand
    sample_list=$work_dir/tophat_output/failedSamples_forTophat.txt
    bash ${script_path}/run_tophat.sh "$sample_list" "$lib" "$strand" "$Bowtie2_genome_index_base" "$transcriptome_index" "$script_path"
fi; done < $horse_trans/working_list.txt
## define the list samples.
while read work_dir; do if [ -d $work_dir/tophat_output/digi_tophat_output ]; then
  rm -f $work_dir/tophat_output/digi_tophat_output/sample_list.txt
  for f in $work_dir/tophat_output/digi_tophat_output/tophat_*; do if [ -d $f ]; then
    echo $f >> $work_dir/tophat_output/digi_tophat_output/sample_list.txt; fi; done;
fi; done < $horse_trans/working_list.txt
### Run Cufflinks: output transcripts.gtf in the same tophat_sample folder
while read work_dir; do
  echo $work_dir
  cd $work_dir/tophat_output/digi_tophat_output
  sample_list=$work_dir/tophat_output/digi_tophat_output/sample_list.txt
  #bash ${script_path}/run_cufflinks_wRef.sh "$sample_list" "$refGTF_file" "$script_path/cufflinks.sh";
  bash ${script_path}/run_cufflinks_noRef.sh "$sample_list" "$script_path/cufflinks_noRef_mask.sh";
done < $horse_trans/working_list.txt    
## relocate the cufflinks analysis results
while read work_dir; do
  while read sample_dir;do if [ -d $sample_dir ];then
    echo $sample_dir
    target_dir=$work_dir/tophat_output/$(basename $sample_dir)
    cp $sample_dir/{transcripts.gtf,skipped.gtf,*.fpkm_tracking,cufflinks.[oe]*} $target_dir/.
  fi; done < $work_dir/tophat_output/digi_tophat_output/sample_list.txt
done < $horse_trans/working_list.txt

############
## Assess computational utilization of cufflinks
cufflinks_utlization=$prepData/${cufflinks_run}_cufflinks_utlization.txt
> $cufflinks_utlization
while read work_dir; do
  cd $work_dir/tophat_output
  sample_list=$work_dir/tophat_output/sample_list.txt
  bash ${script_path}/assess_cufflinks_utlization.sh "$sample_list" "$cufflinks_utlization"
done < $horse_trans/working_list.txt
############
## relocate the cufflinks analysis results
while read work_dir; do if [ -d $work_dir/tophat_output ]; then
  cd $work_dir/tophat_output
  for dir in $work_dir/tophat_output/tophat_*; do if [ -f "$dir"/transcripts.gtf ]; then
    cd $dir
    mkdir $cufflinks_run && \
    mv "$dir"/{transcripts.gtf,skipped.gtf,*.fpkm_tracking,cufflinks.[oe]*} $cufflinks_run/.; fi; done
fi; done < $horse_trans/working_list.txt
########################
### Run cuffmerge: merge the sample assemblies and output merged.gtf in tophat_output/$cufflinks_run/$cuffmerge_run
cuffmerge_output=$cufflinks_run/$cuffmerge_run
while read work_dir; do if [ -d $work_dir/tophat_output ]; then
  cd $work_dir/tophat_output
  for dir in $work_dir/tophat_output/tophat_*; do if [ -f "$dir"/$cufflinks_run/transcripts.gtf ]; then
    echo "$dir"/$cufflinks_run/transcripts.gtf; fi; done > ${cufflinks_run}_assemblies.txt
  rm -fR $cuffmerge_output
  #bash ${script_path}/cuffmerge_withRefGene.sh "$genome" "$cuffmerge_output" "${cufflinks_run}_assemblies.txt" "$refGTF_file"
  isoformfrac=0.05    ## value 1-0.05 & default= 0.05
  bash ${script_path}/cuffmerge_noGTF.sh "$genome" "$cuffmerge_output" "$isoformfrac" "${cufflinks_run}_assemblies.txt"
fi; done < $horse_trans/working_list.txt
## http://cole-trapnell-lab.github.io/cufflinks/cuffcompare/#transfrag-class-codes
##################
### cuffmerge the lab-specific tissue assemblies into tissue specific assemblies
# prepare list of target tissues
rm -f $horse_trans/multi_lib_tissues.txt
for tissue_dir in $prepData/*; do if [[ -d $tissue_dir && $(ls $tissue_dir | wc -l) -gt 1 ]]; then
  echo $tissue_dir >> $horse_trans/multi_lib_tissues.txt; fi; done;

# For every target tissue, cuffmerge the lab-spefific assemblies into one assembly in $tissue_merge/cuffmerge/TISSUE.NAME/withORwithoutRefGuidence.gtf
tissue_Cuffmerge=$tissue_merge/cuffmerge
mkdir -p $tissue_Cuffmerge
cd $tissue_Cuffmerge
while read tissue_dir; do
  tissue=$(basename $tissue_dir)
  mkdir -p $tissue
  rm -f $tissue_dir/${cufflinks_run}_assemblies.txt
  for dir in $tissue_dir/*; do if [ -d "$dir" ]; then
    cat "$dir"/tophat_output/${cufflinks_run}_assemblies.txt >> $tissue_dir/${cufflinks_run}_assemblies.txt; fi; done
  cuffmerge_output=$tissue/$cufflinks_run/$cuffmerge_run
  rm -fR $cuffmerge_output
  #bash ${script_path}/cuffmerge_withRefGene.sh "$genome" "$cuffmerge_output" "$tissue_dir/${cufflinks_run}_assemblies.txt" "$refGTF_file"
  isoformfrac=0.05    ## value 1-0.05 & default= 0.05
  bash ${script_path}/cuffmerge_noGTF.sh "$genome" "$cuffmerge_output" "$isoformfrac" "$tissue_dir/${cufflinks_run}_assemblies.txt"
done < $horse_trans/multi_lib_tissues.txt
##################
### cuffmerge all assemblies into one total assembly
# save the assembly in $horse_trans/total_merge/cuffmerge/withORwithoutRefGuidence.gtf
cd $tissue_Cuffmerge
rm -f $prepData/${cufflinks_run}_assemblies.txt
while read work_dir; do if [ -d $work_dir/tophat_output ]; then
  cat "$work_dir"/tophat_output/${cufflinks_run}_assemblies.txt >> $prepData/${cufflinks_run}_assemblies.txt
fi; done < $horse_trans/working_list.txt

dist_dir="all_tissues_frac$isoformfrac"
mkdir -p $dist_dir
cuffmerge_output=$dist_dir/$cufflinks_run/$cuffmerge_run
#bash ${script_path}/cuffmerge_withRefGene.sh "$genome" "$cuffmerge_output" "$prepData/${cufflinks_run}_assemblies.txt" "$refGTF_file"
bash ${script_path}/cuffmerge_noGTF.sh "$genome" "$cuffmerge_output" "$isoformfrac" "$prepData/${cufflinks_run}_assemblies.txt"

#Construct the transcript fasta file && calculate statistics
cd $tissue_Cuffmerge/$cuffmerge_output
bash $script_path/run_genome_to_cdna_fasta.sh "merged.gtf" "$genome" "transcripts.fasta" "$script_path/genome_to_cdna_fasta.sh"
bash $script_path/run_seq_stats.sh "transcripts.fasta" "primitive_transcriptome.MatzStat"
echo "no of gene: " $(cat merged.gtf | awk -F '[\t"]' '{ print $10 }' |  sort | uniq | wc -l) >> primitive_transcriptome.MatzStat
echo "no of transcripts: " $(cat merged.gtf | awk -F '[\t"]' '{ print $12 }' |  sort | uniq | wc -l) >> primitive_transcriptome.MatzStat
cp primitive_transcriptome.MatzStat $horse_trans/downloads/.
###################
## create a hub for non filtered data
## create list of assemblies from each library
## This is where you can edit the list to restrict the processing for certain target(s)
rm -f $prepData/${cufflinks_run}_${cuffmerge_run}_merged_raw.assemblies.txt
while read work_dir; do
  dir=$work_dir/tophat_output/$cufflinks_run/$cuffmerge_run
  if [ -d $dir ]; then
    echo "$prepData" "${dir#$prepData/}" >> $prepData/${cufflinks_run}_${cuffmerge_run}_merged_raw.assemblies.txt;
fi; done < $horse_trans/working_list.txt

## create list of assemblies for tissues of multiple libraries
rm -f $tissue_Cuffmerge/${cufflinks_run}_${cuffmerge_run}_tissue_raw.assemblies.txt
for tissue in $tissue_Cuffmerge/*/$cufflinks_run/$cuffmerge_run; do if [ -d $tissue ]; then
  echo "$tissue_Cuffmerge" "${tissue#$tissue_Cuffmerge/}" >> $tissue_Cuffmerge/${cufflinks_run}_${cuffmerge_run}_tissue_raw.assemblies.txt;
fi; done
####################
## convert the gtf files into BigBed files & copy the BigBed files to the track hub directory
update=1    ## 0 means do not update Bigbed files & 1 means update
rm -f $horse_trans/Tophat_${cufflinks_run}_${cuffmerge_run}_raw.assemblies.txt
while read ass_path assembly; do
  echo $assembly
  if [ -d "$ass_path/$assembly" ];then
    cd $ass_path/$assembly
  else echo "can not find $ass_path/$assembly"; break;fi
  if [[ ! -f "merged.BigBed" || "$update" -eq 1 ]];then
    targetAss=$"merged.gtf"
    if [ -f "$targetAss" ];then
      bash $script_path/gtfToBigBed.sh "$targetAss" "$genome_dir/$UCSCgenome.chrom.sizes" "$script_path"
    else echo "can not find merged.gtf"; break;fi
    if [ -f $"merged.BigBed" ];then
      identifier=$(echo $assembly | sed 's/\//_/g' | sed 's/_output//g')
      cp merged.BigBed $track_hub/$UCSCgenome/BigBed/${identifier}.BigBed
    else echo "could not make merged.BigBed file"; break; fi
  fi
  echo $ass_path/$assembly >> $horse_trans/Tophat_${cufflinks_run}_${cuffmerge_run}_raw.assemblies.txt;
done < <(cat $prepData/${cufflinks_run}_${cuffmerge_run}_merged_raw.assemblies.txt \
$tissue_Cuffmerge/${cufflinks_run}_${cuffmerge_run}_tissue_raw.assemblies.txt)

## initiate a given track hub for cufflinks_run="nonGuided_Cufflinks"
hub_name=$"HorseTrans_TNGCuffUnfilt"
shortlabel=$"TNGCuffUnfilt"
longlabel=$"Single samlpe refGuided Tophat - nonGuided Cufflinks/Cuffmerge - Unfiltered"
email=$"drtamermansour@gmail.com"
cd $track_hub
bash $script_path/create_trackHub.sh "$UCSCgenome" "$hub_name" "$shortlabel" "$longlabel" "$email"

## edit the trackDb
current_libs=$track_hub/current_libs_$shortlabel
current_tissues=$track_hub/current_tiss_$shortlabel
trackDb=$track_hub/$UCSCgenome/trackDb_$shortlabel.txt
lib_assemblies=$prepData/${cufflinks_run}_${cuffmerge_run}_merged_raw.assemblies.txt
tiss_assemblies=$tissue_Cuffmerge/${cufflinks_run}_${cuffmerge_run}_tissue_raw.assemblies.txt
bash $script_path/edit_trackDb.sh $current_libs $current_tissues $trackDb $lib_assemblies $tiss_assemblies
##########################
## filtering of single exon transfrag completely present within introns of other multiexon transcripts (class code i,e,o): 37464 transcripts
cd $tissue_Cuffmerge/$cuffmerge_output
bash $script_path/gtfToBed.sh "merged.gtf" "$script_path"
cat merged.bed | awk '{if($10>1) print $4}' > multiExon_id
mkdir -p filtered/NoIntronicFrag/prep
grep -F -w -f multiExon_id merged.gtf > filtered/NoIntronicFrag/prep/multiExon.gtf
cd filtered/NoIntronicFrag/prep
assembly="$tissue_Cuffmerge/$cuffmerge_output/merged.gtf"
identifier="nonGuided_Cufflinks_multiExon"
bash ${script_path}/run_cuffcompare.sh "$assembly" "$identifier" "multiExon.gtf" "$script_path/cuffcompare.sh"
mv $(dirname $assembly)/{$identifier.*.refmap,$identifier.*.tmap} .
tail -n+2 nonGuided_Cufflinks_multiExon.merged.gtf.tmap | awk '{if($3!="e" && $3!="i" && $3!="o") print $5}' > keepit.id
grep -F -w -f keepit.id $assembly > ../merged.gtf
cat $assembly | awk -F '[\t"]' '{ print $10 }' |  sort | uniq | wc -l ## no of gene 117083
cat $assembly | awk -F '[\t"]' '{ print $12 }' |  sort | uniq | wc -l ## no of trans 211562
cat ../merged.gtf | awk -F '[\t"]' '{ print $10 }' |  sort | uniq | wc -l ## no of gene 75084
cat ../merged.gtf | awk -F '[\t"]' '{ print $12 }' |  sort | uniq | wc -l ## no of trans 162261

## Using Salmon to eliminate low-expressed transcripts
## exclude isoforms with TPM less than 5% of the total TPM of each locus: 41543 transcript
mkdir -p $tissue_Cuffmerge/$cuffmerge_output/filtered/highExp/prep
cd $tissue_Cuffmerge/$cuffmerge_output/filtered/highExp/prep
assembly="$tissue_Cuffmerge/$cuffmerge_output/filtered/NoIntronicFrag/merged.gtf"
bash $script_path/run_genome_to_cdna_fasta.sh "$assembly" "$genome" "transcripts.fa" "$script_path/genome_to_cdna_fasta.sh"
bash $script_path/run_salmonIndex.sh "horse_index" "transcripts.fa" ${script_path}/salmonIndex.sh
#qsub -v index="horse_index",transcriptome="transcripts.fa" ${script_path}/salmonIndex.sh
while read work_dir; do
  lib=$(basename $work_dir | cut -d"_" -f 1)                      ## PE or SE
  strand=$(basename $work_dir | cut -d"_" -f 3 | sed 's/\./-/')   ## fr-unstranded, fr-firststrand or fr-secondstrand
  identifier=$(echo $work_dir | rev | cut -d"/" -f 1,2 | rev | sed 's/\//_/')
  seq_dir=$work_dir/trimmed_RNA_reads
  bash ${script_path}/run_salmon.sh "$lib" "$strand" "horse_index" "$identifier" "$seq_dir" "$script_path"
done < $horse_trans/working_list.txt
find ./*.quant -name \*.sf -exec grep -H "mapping rate" {} \; | sort > salmonQuant_summary.txt
python $script_path/gather-counts.py -i "$(pwd)"
echo "transcript"$'\t'"length" > transcripts.lengthes
sf=$(find ./*.quant -name \*.sf | head -n1)
cat $sf | grep -v "^#" | awk -F "\t" -v OFS='\t' '{print $1,$2}' >> transcripts.lengthes
#grep "^>" transcripts.fa | sed 's/>//g' > transTogene.map
#module load R/3.0.1
#Rscript ${script_path}/calcTPM.R "$(pwd)"
grep "^>" transcripts.fa | awk -F'[> ]' '{print $3,$2}' > gene_transcript_map
identifier="" ## leave the identifier empty if you want to calculate TPM for all files
bash $script_path/run_calcTPM.sh "$(pwd)" "$identifier" "transcripts.lengthes" "gene_transcript_map" ${script_path}/calcTPM2.R
#Rscript ${script_path}/calcTPM.R "$(pwd)"
cat dataSummary_comp | tail -n+2 | awk '{if($10 >= 5)print $3}' > keepit.id
grep -F -w -f keepit.id $assembly > ../merged.gtf
cat ../merged.gtf | awk -F '[\t"]' '{ print $10 }' |  sort | uniq | wc -l ## no of gene 75067
cat ../merged.gtf | awk -F '[\t"]' '{ print $12 }' |  sort | uniq | wc -l ## no of trans 114830

## exclusion of Mitochondrail contigs & save the final filtered assembly to the main directory
 cat $tissue_Cuffmerge/$cuffmerge_output/filtered/highExp/merged.gtf | awk '$1 != "chrM"' > $tissue_Cuffmerge/$cuffmerge_output/filtered/merged.gtf 
 
## copy the final filtered assembly to the download folder
cp $tissue_Cuffmerge/$cuffmerge_output/filtered/merged.gtf $horse_trans/downloads/filtered_Alltissues_Assembly.GTF

#Construct the transcript fasta file && calculate statistics
cd $tissue_Cuffmerge/$cuffmerge_output/filtered
bash $script_path/run_genome_to_cdna_fasta.sh "merged.gtf" "$genome" "transcripts.fasta" "$script_path/genome_to_cdna_fasta.sh"
bash $script_path/run_seq_stats.sh "transcripts.fasta" "filtered_transcriptome.MatzStat"
echo "no of gene: " $(cat merged.gtf | awk -F '[\t"]' '{ print $10 }' |  sort | uniq | wc -l) >> filtered_transcriptome.MatzStat  
echo "no of transcripts: " $(cat merged.gtf | awk -F '[\t"]' '{ print $12 }' |  sort | uniq | wc -l) >> filtered_transcriptome.MatzStat
cp filtered_transcriptome.MatzStat $horse_trans/downloads/.

## Use the assembly version with mitochondrial contigs to allow proper calculation of mapping rate but remove these contigs from final target assemblies
assembly="$tissue_Cuffmerge/$cuffmerge_output/filtered/highExp/merged.gtf"
cd $(dirname $assembly)
bash $script_path/run_genome_to_cdna_fasta.sh "$assembly" "$genome" "transcripts.fa" "$script_path/genome_to_cdna_fasta.sh"
bash $script_path/run_salmonIndex.sh "horse_index" "transcripts.fa" ${script_path}/salmonIndex.sh
#qsub -v index="horse_index",transcriptome="transcripts.fa" ${script_path}/salmonIndex.sh
while read work_dir; do
  lib=$(basename $work_dir | cut -d"_" -f 1)                      ## PE or SE
  strand=$(basename $work_dir | cut -d"_" -f 3 | sed 's/\./-/')   ## fr-unstranded, fr-firststrand or fr-secondstrand
  identifier=$(echo $work_dir | rev | cut -d"/" -f 1,2 | rev | sed 's/\//_/')
  seq_dir=$work_dir/trimmed_RNA_reads
  bash ${script_path}/run_salmon.sh "$lib" "$strand" "horse_index" "$identifier" "$seq_dir" "$script_path"
done < $horse_trans/working_list.txt
find ./*.quant -name *.sf -exec grep -H "mapping rate" {} \; | sort > salmonQuant_summary.txt
echo "Total no of input reads" > salmonQuant_summary_detailed.txt
find ./*.quant -name salmon_quant.log -exec grep -H "total fragments" {} \; | sort >> salmonQuant_summary_detailed.txt
echo "No of mapped reads" >> salmonQuant_summary_detailed.txt
find ./*.quant -name salmon_quant.log -exec grep -H "total reads" {} \; | sort >> salmonQuant_summary_detailed.txt
echo "Mapping rate" >> salmonQuant_summary_detailed.txt
find ./*.quant -name salmon_quant.log -exec grep -H "Mapping rate" {} \; | sort >> salmonQuant_summary_detailed.txt
python $script_path/gather-counts2.py -i "$(pwd)"
echo "transcript"$'\t'"length" > transcripts.lengthes
sf=$(find ./*.quant -name \*.sf | head -n1)
cat $sf | grep -v "^#" | awk -F "\t" -v OFS='\t' '{print $1,$2}' >> transcripts.lengthes
#grep "^>" transcripts.fa | sed 's/>//g' > transTogene.map
#module load R/3.0.1
grep "^>" transcripts.fa | awk -F'[> ]' '{print $3,$2}' > gene_transcript_map

## library specific expression and assembly
while read work_dir; do
  tissue=$(basename $(dirname $work_dir))
  lib=$(basename $work_dir)
  target=$tissue"_"$lib
  echo $target
  bash $script_path/run_calcTPM.sh "$(pwd)" "$target" "transcripts.lengthes" "gene_transcript_map" ${script_path}/calcTPM2.R
  #Rscript ${script_path}/calcTPM_tis.R "$(pwd)" "$target" >> targets_list # > /dev/null
  dir=$work_dir/tophat_output/$cufflinks_run/$cuffmerge_run/filtered
  mkdir -p $dir
  cat $target.dataSummary_comp | tail -n+2 | awk '{if($10 >= 5)print $3}' > $target.keepit.id
  grep -F -w -f $target.keepit.id $assembly | awk '$1 != "chrM"' > $dir/merged.gtf
  ## copy the annotation to the download folder
  cp $dir/merged.gtf $horse_trans/downloads/$target.gtf
  ## statistics (no of genes and transcripts)
  cat $dir/merged.gtf | awk -F '[\t"]' '{ print $10 }' |  sort | uniq | wc -l
  cat $dir/merged.gtf | awk -F '[\t"]' '{ print $12 }' |  sort | uniq | wc -l
done < $horse_trans/working_list.txt > $horse_trans/libAsmStats.txt

## Tissue specific expression and assembly
while read work_dir; do
  target=$(basename $work_dir)
  echo $target
  bash $script_path/run_calcTPM.sh "$(pwd)" "$target" "transcripts.lengthes" "gene_transcript_map" ${script_path}/calcTPM2.R
  #Rscript ${script_path}/calcTPM_tis.R "$(pwd)" "$target" >> targets_list # > /dev/null
  dir=$tissue_Cuffmerge/$target/$cufflinks_run/$cuffmerge_run/filtered
  mkdir -p $dir
  cat $target.dataSummary_comp | tail -n+2 | awk '{if($10 >= 5)print $3}' > $target.keepit.id
  grep -F -w -f $target.keepit.id $assembly | awk '$1 != "chrM"' > $dir/merged.gtf
  ## copy the annotation to the download folder
  cp $dir/merged.gtf $horse_trans/downloads/$target.gtf
  ## statistics
  cat $dir/merged.gtf | awk -F '[\t"]' '{ print $10 }' |  sort | uniq | wc -l
  cat $dir/merged.gtf | awk -F '[\t"]' '{ print $12 }' |  sort | uniq | wc -l
done < $horse_trans/multi_lib_tissues.txt > $horse_trans/tisAsmStats.txt
###################
## calculate tissue specific expression
targets=()
i=1
rm temp.*
while read target;do
  f="$target".dataSummary_comp
  if [ ! -f $f ];then f="$target"_*.dataSummary_comp;fi
  cat $f | tail -n+2 | awk '{print $2,$7}' | uniq > $f.gene
  cat $f | tail -n+2 | awk '{print $3,$6}' > $f.isoform
  targets+=($target)
  if [ $i -eq 1 ];then cat $f.gene > temp.$i;else join -t" " --nocheck-order temp.$((i-1)) $f.gene > temp.$i;fi
  if [ $i -eq 1 ];then cat $f.isoform > isotemp.$i;else join -t" " --nocheck-order isotemp.$((i-1)) $f.isoform > isotemp.$i;fi
  ((i+=1))
done < <(ls *_*.dataSummary_comp | awk -F '_' '{print $1}' | sort | uniq)
echo "geneName" "${targets[@]}" > allTissues_geneTPM
cat temp.$((i-1)) >> allTissues_geneTPM
echo "isoformName" "${targets[@]}" > allTissues_isoformTPM
cat isotemp.$((i-1)) >> allTissues_isoformTPM

##print no of gene/isoform expressed, expressed uniqely, not expressed uniquely
i=0
n=${#targets[@]}
while [ $i -lt $n ];do
 echo ${targets[$i]}
 cat allTissues_geneTPM | awk -v x=$((i+2)) '$x>0' | wc -l
 cat allTissues_isoformTPM | awk -v x=$((i+2)) '$x>0' | wc -l

 cat allTissues_geneTPM > tempGene; cat allTissues_isoformTPM > isoform;
 for x in `seq 2 $((n+1))`;do 
   if [ $x -eq $((i+2)) ];then awk -v x=$x '$x>0' tempGene > tempGene2; else awk -v x=$x '$x==0' tempGene > tempGene2;fi
   if [ $x -eq $((i+2)) ];then awk -v x=$x '$x>0' isoform > isoform2; else awk -v x=$x '$x==0' isoform > isoform2;fi
   mv tempGene2 tempGene; mv isoform2 isoform;done
  cat tempGene | wc -l; cat isoform | wc -l;

 cat allTissues_geneTPM > tempGene; cat allTissues_isoformTPM > tempIsoform;
 for x in `seq 2 $((n+1))`;do 
   if [ $x -eq $((i+2)) ];then awk -v x=$x '$x==0' tempGene > tempGene2; else awk -v x=$x '$x>0' tempGene > tempGene2;fi
   if [ $x -eq $((i+2)) ];then awk -v x=$x '$x==0' tempIsoform > tempIsoform2; else awk -v x=$x '$x>0' tempIsoform > tempIsoform2;fi
   mv tempGene2 tempGene; mv tempIsoform2 tempIsoform;done
  cat tempGene | wc -l; cat tempIsoform | wc -l;
  
 ((i+=1))
done > tissueSpecificSummary
rm tempGene tempIsoform

echo "All Tissues" >> tissueSpecificSummary
cat allTissues_geneTPM > tempGene; cat allTissues_isoformTPM > tempIsoform;
for x in `seq 2 $((n+1))`;do 
  awk -v x=$x '$x>0' allTissues_geneTPM > tempGene.$x; awk -v x=$x '$x>0' allTissues_isoformTPM > tempIsoform.$x;
  awk -v x=$x '$x>0' tempGene > tempGene2; awk -v x=$x '$x>0' tempIsoform > tempIsoform2; mv tempGene2 tempGene; mv tempIsoform2 tempIsoform;done
cat tempGene.* | sort | uniq | wc -l  >> tissueSpecificSummary; cat tempIsoform.* | sort | uniq | wc -l  >> tissueSpecificSummary;
cat tempGene | wc -l  >> tissueSpecificSummary; cat tempIsoform | wc -l  >> tissueSpecificSummary;

## copy tabulated expression files to the download folder
cp allTissues_geneTPM allTissues_isoformTPM $horse_trans/downloads/.
###################
## create hub for filtered data
## create list of assemblies from each library
## This is where you can edit the list to restrict the processing for certain target(s)
rm -f $prepData/${cufflinks_run}_${cuffmerge_run}_merged_assemblies.txt
while read work_dir; do
  dir=$work_dir/tophat_output/$cufflinks_run/$cuffmerge_run/filtered
  if [ -d $dir ]; then
    echo "$prepData" "${dir#$prepData/}" >> $prepData/${cufflinks_run}_${cuffmerge_run}_merged_assemblies.txt;
fi; done < $horse_trans/working_list.txt

## create list of assemblies for tissues of multiple libraries
rm -f $tissue_Cuffmerge/${cufflinks_run}_${cuffmerge_run}_tissue_assemblies.txt
for tissue in $tissue_Cuffmerge/*/$cufflinks_run/$cuffmerge_run/filtered; do if [ -d $tissue ]; then
  echo "$tissue_Cuffmerge" "${tissue#$tissue_Cuffmerge/}" >> $tissue_Cuffmerge/${cufflinks_run}_${cuffmerge_run}_tissue_assemblies.txt;
fi; done

## create list of filtered assemblies
#rm -f $tissue_Cuffmerge/${cufflinks_run}_${cuffmerge_run}_subtissue_assemblies.txt
#for tissue in $tissue_Cuffmerge/*/$cufflinks_run/$cuffmerge_run/filtered/*; do if [ -d $tissue ]; then
#  echo "$tissue_Cuffmerge" "${tissue#$tissue_Cuffmerge/}" >> $tissue_Cuffmerge/${cufflinks_run}_${cuffmerge_run}_subtissue_assemblies.txt;
#fi; done
####################
## convert the gtf files into BigBed files & copy the BigBed files to the track hub directory
update=0    ## 0 means do not update Bigbed files & 1 means update
rm -f $horse_trans/Tophat_${cufflinks_run}_${cuffmerge_run}_assemblies.txt
while read ass_path assembly; do
  echo $assembly
  if [ -d "$ass_path/$assembly" ];then
    cd $ass_path/$assembly
  else echo "can not find $ass_path/$assembly"; break;fi
  if [[ ! -f "merged.BigBed" || "$update" -eq 1 ]];then
    targetAss=$"merged.gtf"
    if [ -f "$targetAss" ];then
      bash $script_path/gtfToBigBed.sh "$targetAss" "$genome_dir/$UCSCgenome.chrom.sizes" "$script_path"
    else echo "can not find merged.gtf"; break;fi
    if [ -f $"merged.BigBed" ];then
      identifier=$(echo $assembly | sed 's/\//_/g' | sed 's/_output//g')
      cp merged.BigBed $track_hub/$UCSCgenome/BigBed/${identifier}.BigBed
    else echo "could not make merged.BigBed file"; break; fi
  fi
  echo $ass_path/$assembly >> $horse_trans/Tophat_${cufflinks_run}_${cuffmerge_run}_assemblies.txt;
done < <(cat $prepData/${cufflinks_run}_${cuffmerge_run}_merged_assemblies.txt \
             $tissue_Cuffmerge/${cufflinks_run}_${cuffmerge_run}_tissue_assemblies.txt)
#             $tissue_Cuffmerge/${cufflinks_run}_${cuffmerge_run}_subtissue_assemblies.txt)

## initiate a given track hub for cufflinks_run
if [ "${cufflinks_run}_${cuffmerge_run}" == "nonGuided_Cufflinks_nonGuided_Cuffmerge" ];then
 hub_name=$"HorseTrans_TopNonGuidCuff"
 shortlabel=$"TopNonGuidCuff"
 longlabel=$"Single samlpe refGuided Tophat - nonGuided Cufflinks/Cuffmerge"
elif [ "${cufflinks_run}_${cuffmerge_run}" == "refGeneGuided_Cufflinks_refGeneGuided_Cuffmerge" ];then
 hub_name=$"HorseTrans_TopGuidedCuff"
 shortlabel=$"TopGuidedCuff"
 longlabel=$"Single samlpe refGuided Tophat/Cufflinks - Guided Cuffmerge"
fi
email=$"drtamermansour@gmail.com"
cd $track_hub
bash $script_path/create_trackHub.sh "$UCSCgenome" "$hub_name" "$shortlabel" "$longlabel" "$email"

## edit the trackDb
current_libs=$track_hub/current_libs_$shortlabel
current_tissues=$track_hub/current_tiss_$shortlabel
trackDb=$track_hub/$UCSCgenome/trackDb_$shortlabel.txt
lib_assemblies=$prepData/${cufflinks_run}_${cuffmerge_run}_merged_assemblies.txt
tiss_assemblies=$tissue_Cuffmerge/${cufflinks_run}_${cuffmerge_run}_tissue_assemblies.txt
bash $script_path/edit_trackDb.sh $current_libs $current_tissues $trackDb $lib_assemblies $tiss_assemblies
#bash $script_path/edit_trackDb.sh $current_libs $current_tissues $trackDb \
#        <(cat $prepData/${cufflinks_run}_${cuffmerge_run}_merged_assemblies.txt \
#            $tissue_Cuffmerge/${cufflinks_run}_${cuffmerge_run}_subtissue_assemblies.txt) $tiss_assemblies

## copy the BED files to the download folder
while read ass_path assembly; do
  id=$(echo $assembly | cut -d "/" -f1,2 | sed 's|/|.|')
  cp $ass_path/$assembly/merged_sorted.bed $horse_trans/downloads/$id.bed
done < <(cat $prepData/${cufflinks_run}_${cuffmerge_run}_merged_assemblies.txt \
             $tissue_Cuffmerge/${cufflinks_run}_${cuffmerge_run}_tissue_assemblies.txt)
##########################################################################################
## Run Cuffcompare with public annotations
mkdir -p $horse_trans/cuffcompare
cd $horse_trans/cuffcompare
while read root_dir asm_dir; do echo $asm_dir $root_dir/$asm_dir/*.gtf >> assmblies.txt;done < $pubAssemblies/public_assemblies.txt
echo ensGTF_file ${ensGTF_file}  >> assmblies.txt
echo refGTF_file ${refGTF_file}  >> assmblies.txt
echo $cufflinks_run.$cuffmerge_run $tissue_Cuffmerge/$cuffmerge_output/filtered/merged.gtf  >> assmblies.txt

while read ref_name ref_assembly;do
  while read asm_name assembly;do if [ "$assembly" != "$ref_assembly" ];then
    mkdir -p $horse_trans/cuffcompare/$asm_name.vs.$ref_name
    cd $horse_trans/cuffcompare/$asm_name.vs.$ref_name
    identifier=$asm_name.vs.$ref_name
    echo $identifier
    #echo "$assembly" "$identifier" "${ref_assembly}" >> $horse_trans/cuffcompare/temp
    bash ${script_path}/run_cuffcompare.sh "$assembly" "$identifier" "${ref_assembly}" "$script_path/cuffcompare.sh"
  fi; done < $horse_trans/cuffcompare/assmblies.txt
done < $horse_trans/cuffcompare/assmblies.txt

echo "# sn = Sensitivity (as defined in Burset, M., Guigó, R. : Evaluation of gene structure prediction programs (1996) Genomics, 34 (3), pp. 353-367. doi: 10.1006/geno.1996.0298)" > $horse_trans/cuffcompare/cuffcomp_summary
echo -e "quary\tquary_loci\treference\tref_loci\tbase_sen(%)\texon_sn(%)\tintron_sn(%)\tintron_chain_sn(%)\tlocus_sn(%)\tmissed_exons\tmissed_introns\tmissed_loci\tnovel_loci" >> $horse_trans/cuffcompare/cuffcomp_summary
while read ref_name ref_assembly;do
  while read asm_name assembly;do if [ "$assembly" != "$ref_assembly" ];then
   cd $horse_trans/cuffcompare/$asm_name.vs.$ref_name
   quary=$asm_name
   ref=$ref_name
   base_sn=$(grep "Base level:" $asm_name.vs.$ref_name | awk '{print $3}')
   exon_sn=$(grep "Exon level:" $asm_name.vs.$ref_name | awk '{print $3}')
   intron_sn=$(grep "Intron level:" $asm_name.vs.$ref_name | awk '{print $3}')
   ic_sn=$(grep "Intron chain level:" $asm_name.vs.$ref_name | awk '{print $4}')
   locus_sn=$(grep "Locus level:" $asm_name.vs.$ref_name | awk '{print $3}')
   #matchIC=$(grep "Matching intron chains:" $asm_name.vs.$ref_name | awk '{print $4}')
   #matchLoci=$(grep "Matching intron chains:" $asm_name.vs.$ref_name | awk '{print $3}')
   missedExons=$(grep "Missed exons:" $asm_name.vs.$ref_name | sed 's/ //g' | awk -F'[:/\t]' 'BEGIN{OFS="";}{print $2,$4}')
   missedIntrons=$(grep "Missed introns:" $asm_name.vs.$ref_name | sed 's/ //g' | awk -F'[:/\t]' 'BEGIN{OFS="";}{print $2,$4}')
   missedLoci=$(grep "Missed loci:" $asm_name.vs.$ref_name | sed 's/ //g' | awk -F'[:/\t]' 'BEGIN{OFS="";}{print $2,$4}')
   refLoci=$(grep "Missed loci:" $asm_name.vs.$ref_name | sed 's/ //g' | awk -F'[:/\t]' '{print $3}')
   novelLoci=$(grep "Novel loci:" $asm_name.vs.$ref_name | sed 's/ //g' | awk -F'[:/\t]' 'BEGIN{OFS="";}{print $2,$4}')
   quaryLoci=$(grep "Novel loci:" $asm_name.vs.$ref_name | sed 's/ //g' | awk -F'[:/\t]' '{print $3}')
   echo -e "$quary\t$quaryLoci\t$ref\t$refLoci\t$base_sn\t$exon_sn\t$intron_sn\t$ic_sn\t$locus_sn\t$missedExons\t$missedIntrons\t$missedLoci\t$novelLoci" >> $horse_trans/cuffcompare/cuffcomp_summary
  fi; done < $horse_trans/cuffcompare/assmblies.txt
done < $horse_trans/cuffcompare/assmblies.txt
grep -v -w "refGTF_file" $horse_trans/cuffcompare/cuffcomp_summary > $horse_trans/cuffcompare/cuffcomp_summary_NOrefGTF

cd $horse_trans/cuffcompare
while read ref_name ref_assembly;do
  while read asm_name assembly;do if [ "$assembly" != "$ref_assembly" ];then
    cd $horse_trans/cuffcompare/$asm_name.vs.$ref_name
    identifier=$asm_name.vs.$ref_name
    mv $(dirname $assembly)/{$identifier.*.refmap,$identifier.*.tmap} .
  fi; done < $horse_trans/cuffcompare/assmblies.txt
done < $horse_trans/cuffcompare/assmblies.txt

## identify complex loci: We define the transcripts in the quary assembly that align with complex loci in the reference. A locus would be complex if it has an overlapping genes already or if one quary transcript (or more) align with more than one reference gene
cd $horse_trans/cuffcompare
while read ref_name ref_assembly;do
  while read asm_name assembly;do if [ "$assembly" != "$ref_assembly" ];then
    cd $horse_trans/cuffcompare/$asm_name.vs.$ref_name
    #cat *.loci | awk '{print $3}' | sed 's/|.*,/ /g' | sed 's/|.*//' | awk '{delete refs;for (i = 1; i <= NF; i++) {refs[$i]++}; if (length(refs) > 1) {for(gene in refs) {print gene;} } }' > loci.ref.crowded
    cat *.loci | awk '{print $3}' | sed 's/|.*,/ /g' | sed 's/|.*//' | awk '{delete refs;for (i = 1; i <= NF; i++) {refs[$i]++}; print length(refs);}' > loci.ref.freq
    paste *.loci loci.ref.freq > loci.ref.freq2
    cat loci.ref.freq2 | awk '($5>1){print $4}' | tr "\," "\n" > $asm_name.vs.$ref_name.complex
    wc -l $asm_name.vs.$ref_name.complex
  fi; done < $horse_trans/cuffcompare/assmblies.txt
done < $horse_trans/cuffcompare/assmblies.txt > $horse_trans/cuffcompare/summary_complexTrans.txt
#####################
cd $horse_trans/cuffcompare/nonGuided_Cufflinks.nonGuided_Cuffmerge.vs.NCBI
## change of isoform length
cat nonGuided_Cufflinks.nonGuided_Cuffmerge.vs.NCBI.merged.gtf.tmap | awk '($3=="="){print $1,$2,$5,$11,$12,$13}' > matchingIsoforms  ## 10427 ## ref_gene_id, ref_Id, cuff_Id, Cuff_len, major_iso_id, ref_len
cat matchingIsoforms | awk '$2~"^[XN]M"' >  matchingIsoforms_PtnCoding ## 9736 (the remaining=691 are non-ptn coding)
cat matchingIsoforms_PtnCoding | awk '{print $1}' | uniq | wc -l ## 7419 (no of genes)
cat matchingIsoforms_PtnCoding | awk '($4-$6)>0' > matching_increased ## 8899
cat matching_increased | awk '{print $1}' | uniq | wc -l ## 6817 (no of genes)
cat matching_increased | awk '{total = total + ($4-$6)}END{print total}'  ## 29697025 (~3.3Kb on ave)
cat matchingIsoforms_PtnCoding | awk '($4-$6)<0' > matching_decreased ## 831
cat matching_decreased | awk '{print $1}' | uniq | wc -l ## 718 (no of genes)
cat matching_decreased | awk '{total = total + ($6-$4)}END{print total}'  ## 339273 (~0.4Kb on ave)
cat matchingIsoforms_PtnCoding | awk '($4-$6)==0' > matching_noChange ## 6
cat matching_noChange | awk '{print $1}' | uniq | wc -l ## 6 (no of genes)
######################
mkdir $horse_trans/cuffcompare_Ann
## count the genes/transcripts  of each assembly
## Note: Cuffcompare discard some transcripts from ref & quary (but with different algorithms so that the no discarded transcripts from the same annotation differs if it is used as reference or quary
cd $horse_trans/cuffcompare_Ann
echo "## gene name duplications happen on different chromosomes and on the same chromosomes in one locus but with different orintations or in multiple loci but there is no name duplictation for transcripts" > summary_counts
while read ref_name ref_assembly;do
  ## no of genes
  echo $ref_name "Genes:actual no and uniqe names"
  cat $ref_assembly | awk -F '[\t"]' '{print $1,$7,$10}' | uniq | wc -l   ## 24483
  cat $ref_assembly | awk -F '[\t"]' '{print $10}' | sort | uniq | wc -l   ## 24317
  ## frequency fo gene name duplication on the same chr with the same orinataion but different loci
  cat $ref_assembly | awk -F '[\t"]' '{print $1,$7,$10}' | sort | uniq -c | sort -nr > $ref_name.genesDup_count

  ## no of transcripts (there is no name duplictation for transcripts)
  echo $ref_name "Transcripts:actual no and uniqe names"
  cat $ref_assembly | awk -F '[\t"]' '{print $1,$7,$12}' | uniq | wc -l   ## 43417

  ## make a transcript to gene map
  echo -e "transcript.ID\tgene.ID\tchr\tstrand" > $ref_name.transTogene
  cat $ref_assembly | awk -F '[\t"]' 'BEGIN{OFS="\t";} {print $12,$10,$1,$7}' | uniq >> $ref_name.transTogene
done < $horse_trans/cuffcompare/assmblies.txt >> summary_counts

## Transcriptome annoatation table: marge all the tmap files for each annoation as a quary aganist all other annotations as references
while read asm_name assembly;do
  cp $asm_name.transTogene $asm_name.merge
  while read ref_name ref_assembly;do if [ "$assembly" != "$ref_assembly" ];then
    identifier=$asm_name.vs.$ref_name
    echo $identifier
    Rscript -e 'args=(commandArgs(TRUE)); data1=read.table(args[1],sep="\t",header=T,row.names=NULL); data2=read.table(args[2], header=T,row.names=NULL,sep="\t"); colnames(data2)[2]=args[3];dataMerge=merge(data1,data2[,c(5,11,12,2,1,13,3)],by.x="transcript.ID",by.y="cuff_id",all.x=T, all.y=T); write.table(dataMerge,args[1], sep="\t", quote=F, row.names=F, col.names=T);' $asm_name.merge $horse_trans/cuffcompare/$identifier/$identifier.*.tmap $ref_name
  fi; done < $horse_trans/cuffcompare/assmblies.txt
  cat $asm_name.merge | cut -f 1-10,13-16,19-22,25-28,31-34 > $asm_name.merge.reduced
done < $horse_trans/cuffcompare/assmblies.txt

## make another version with index for complex regions
while read asm_name assembly;do
  cp $asm_name.merge.reduced $asm_name.merge.reduced.complex
  while read ref_name ref_assembly;do if [ "$assembly" != "$ref_assembly" ];then
    identifier=$asm_name.vs.$ref_name
    echo $identifier
    identifier2=$ref_name.vs.$asm_name
    Rscript -e 'args=(commandArgs(TRUE)); data1=read.table(args[1],sep="\t",header=T,row.names=NULL);'\
'data2=read.table(args[2], header=F,row.names=NULL,sep="\t"); data2$V2="c"; colnames(data2)=c("transcript.ID",args[3]);'\
'dataMerge=merge(data1,data2,by="transcript.ID",all.x=T);'\
'data3=read.table(args[4], header=F,row.names=NULL,sep="\t"); data3$V2="c"; colnames(data3)=c("transcript.ID",args[5]);'\
'dataMerge2=merge(dataMerge,data3,by="transcript.ID",all.x=T);'\
'write.table(dataMerge2,args[1], sep="\t", quote=F, row.names=F, col.names=T);' $asm_name.merge.reduced.complex $horse_trans/cuffcompare/$identifier/$identifier.complex $identifier.complex $horse_trans/cuffcompare/$identifier2/$identifier2.complex $identifier2.complex
  fi; done < $horse_trans/cuffcompare/assmblies.txt
done < $horse_trans/cuffcompare/assmblies.txt

## copy the cuffcompare merged tables to the download folder
cp *.reduced *.reduced.complex $horse_trans/downloads/.

ann="nonGuided_Cufflinks.nonGuided_Cuffmerge.merge.reduced"
## R plot to compare the current assembly with the 4 public assemblies
bash $script_path/run_compAn.sh "$ann" "${ann%.merge.reduced}.transcriptsCompare.pdf" $script_path/compAn.R;
## R plot to assess the distribution of class codes (according to comparison with NCBI assembly) per chromosome
bash $script_path/run_compNCBIperChr.sh "$ann" "$genome_dir/$UCSCgenome.chrom.sizes" "${ann%.merge.reduced}.transCompareNCBIperChr.pdf" $script_path/compNCBI_PerCh.R;
#######################################################################
## compare The filtered assembly to non-horse Refgene tranascripts & gene prediction models
mkdir $horse_trans/consAna
cd $horse_trans/consAna

wget http://hgdownload.cse.ucsc.edu/goldenPath/equCab2/database/xenoRefGene.txt.gz
zcat xenoRefGene.txt.gz | cut -f2-16 | $script_path/UCSC_kent_commands/genePredToGtf file stdin xenoRefGene.gtf

wget http://hgdownload.cse.ucsc.edu/goldenPath/equCab2/database/transMapAlnRefSeq.txt.gz
zcat transMapAlnRefSeq.txt.gz | cut -f2-22 > transMapAlnRefSeq.psl
$script_path/UCSC_kent_commands/pslToBed transMapAlnRefSeq.psl transMapAlnRefSeq.bed
$script_path/UCSC_kent_commands/bedToGenePred transMapAlnRefSeq.bed transMapAlnRefSeq.GenePred
$script_path/UCSC_kent_commands/genePredToGtf file transMapAlnRefSeq.GenePred transMapAlnRefSeq.gtf
rm transMapAlnRefSeq.psl transMapAlnRefSeq.bed transMapAlnRefSeq.GenePred

wget http://hgdownload.cse.ucsc.edu/goldenPath/equCab2/database/augustusGene.txt.gz
zcat augustusGene.txt.gz | cut -f2-16 | $script_path/UCSC_kent_commands/genePredToGtf file stdin augustusGene.gtf

wget http://hgdownload.cse.ucsc.edu/goldenPath/equCab2/database/geneid.txt.gz
zcat geneid.txt.gz | cut -f2-16 | $script_path/UCSC_kent_commands/genePredToGtf file stdin geneid.gtf

wget http://hgdownload.cse.ucsc.edu/goldenPath/equCab2/database/genscan.txt.gz
zcat genscan.txt.gz | cut -f2-16 | $script_path/UCSC_kent_commands/genePredToGtf file stdin genscan.gtf

wget http://hgdownload.cse.ucsc.edu/goldenPath/equCab2/database/nscanGene.txt.gz
zcat nscanGene.txt.gz | cut -f2-16 | $script_path/UCSC_kent_commands/genePredToGtf file stdin nscanGene.gtf

rm -f pred_assemblies.txt
for asm in *.gtf; do
 echo "${asm%.gtf}" "$(pwd)/${asm}" >> pred_assemblies.txt;
done

asm_name=$cufflinks_run.$cuffmerge_run
assembly=$tissue_Cuffmerge/$cuffmerge_output/filtered/merged.gtf
while read ref_name ref_assembly;do
  mkdir -p $horse_trans/consAna/$asm_name.vs.$ref_name
  cd $horse_trans/consAna/$asm_name.vs.$ref_name
  identifier=$asm_name.vs.$ref_name
  echo $identifier
  #echo "$assembly" "$identifier" "${ref_assembly}" >> $horse_trans/cuffcompare/temp
  bash ${script_path}/run_cuffcompare.sh "$assembly" "$identifier" "${ref_assembly}" "$script_path/cuffcompare.sh"
done < pred_assemblies.txt

cd $horse_trans/consAna
while read ref_name ref_assembly;do
  cd $horse_trans/consAna/$asm_name.vs.$ref_name
  identifier=$asm_name.vs.$ref_name
  mv $(dirname $assembly)/{$identifier.*.refmap,$identifier.*.tmap} .
done < pred_assemblies.txt

## make a transcript to gene map
cd $horse_trans/consAna
echo -e "transcript.ID\tgene.ID\tchr\tstrand" > $asm_name.cons.merge
cat $assembly | awk -F '[\t"]' 'BEGIN{OFS="\t";} {print $12,$10,$1,$7}' | uniq >> $asm_name.cons.merge

## marge all the tmap files for each annoation as a quary aganist all other annotations as references
while read ref_name ref_assembly;do
 identifier=$asm_name.vs.$ref_name
 echo $identifier
 Rscript -e 'args=(commandArgs(TRUE)); data1=read.table(args[1],sep="\t",header=T,row.names=NULL);'\
'data2=read.table(args[2], header=T,row.names=NULL,sep="\t");'\
'colnames(data2)[-c(5,11,12)]=as.vector(sapply(args[3], paste0, colnames(data2)[-c(5,11,12)]));'\
'dataMerge=merge(data1,data2[,c(5,11,12,2,1,13,3)],by.x="transcript.ID",by.y="cuff_id",all.x=T, all.y=T);'\
'write.table(dataMerge,args[1], sep="\t", quote=F, row.names=F, col.names=T);' $asm_name.cons.merge $horse_trans/consAna/$identifier/$identifier.*.tmap "$ref_name."
done < pred_assemblies.txt
cat $asm_name.cons.merge | cut -f 1-10,13-16,19-22,25-28,31-34,37-40 > $asm_name.cons.merge.reduced
###########################################################################################
## run Transdecoder to predict ORFs with homology options
#bash $script_path/run_transdecoder.sh <(echo "$tissue_Cuffmerge/$cuffmerge_output/filtered") $genome $refPtn $refPfam $script_path/transdecoder.sh
assembly="$tissue_Cuffmerge/$cuffmerge_output/filtered"
mkdir $assembly/transdecoder
cd $assembly/transdecoder
#Construct the transcript fasta file
bash $script_path/run_genome_to_cdna_fasta.sh "$assembly/merged.gtf" "$genome" "transcripts.fasta" "$script_path/genome_to_cdna_fasta.sh"
# extract the long open reading frames
bash $script_path/run_getLongORFs.sh "transcripts.fasta" "$script_path/getLongORFs.sh"
## identify ORFs with homology to known proteins via blast and pfam searches.
mkdir tempPep && cd tempPep
cp ../transcripts.fasta.transdecoder_dir/longest_orfs.pep .
$script_path/splitFasta.pl longest_orfs.pep 50
for pep in subset[1-5][0-9]_longest_orfs.pep;do
  label=${pep%_longest_orfs.pep}
#  bash $script_path/run_blast.sh "$pep" "$refPtn" $label."blastp.outfmt6" "$script_path/blastp.sh"
  bash $script_path/run_hmmscan.sh "$pep" "$refPfam" $label."pfam.domtblout" "$script_path/hmmscan.sh"
done
cat subset*.blastp.outfmt6 >> ../blastp.outfmt6
cat subset*.pfam.domtblout >> ../pfam.domtblout
## predict the likely coding regions
cd ../
bash $script_path/run_transdecoderPredict.sh "transcripts.fasta" "pfam.domtblout" "blastp.outfmt6" "$script_path/transdecoderPredict.sh"

# convert the transcript structure GTF file to an alignment-GFF3 formatted file
#module load TransDecoder/2.0.1
#decoderUtil=$"/opt/software/TransDecoder/2.0.1--GCC-4.4.5/util"
$script_path/decoderUtil/cufflinks_gtf_to_alignment_gff3.pl "$assembly/merged.gtf" > transcripts.gff3
# generate a genome-based coding region annotation file
$script_path/decoderUtil/cdna_alignment_orf_to_genome_orf.pl transcripts.fasta.transdecoder.gff3 transcripts.gff3 transcripts.fasta 1> transcripts.fasta.transdecoder.genome.gff3 2> sterr

grep "Warning" sterr > warnings.txt && rm sterr
# convert the genome-based gene-gff3 file to bed
$script_path/decoderUtil/gff3_file_to_bed.pl transcripts.fasta.transdecoder.genome.gff3 > transcripts.fasta.transdecoder.genome.bed

tail -n+2 transcripts.fasta.transdecoder.bed | awk -F '\t' '{print $1}' > Trans_ID
tail -n+2 transcripts.fasta.transdecoder.bed | awk -F '[\t:]' '{print $6}' | awk -F '_' '{print $1}' > ORF_len
paste Trans_ID ORF_len > all_ORFs
sort -k1,1 -k2,2rg all_ORFs | sort -u -k1,1 --merge > longest_ORFs
wc -l longest_ORFs # 65062  ## the number of transcripts with likely coding sequences 
wc -l all_ORFs # 149298  ## all signifcant ORFs
##########################################################################################
## novel genes
## add the length of longest ORF and number of exons to the annotation file
ann=$horse_trans/cuffcompare_Ann/nonGuided_Cufflinks.nonGuided_Cuffmerge.merge.reduced
longestORF=$tissue_Cuffmerge/$cuffmerge_output/filtered/transdecoder/longest_ORFs
asmBed=$tissue_Cuffmerge/$cuffmerge_output/filtered/merged.bed
Rscript -e 'args=(commandArgs(TRUE)); data1=read.table(args[1],header=T,sep="\t");'\
'data2=read.table(args[2], header=F,sep="\t"); colnames(data2)=c("transcript.ID","longest_ORF");'\
'dataMerge=merge(data1,data2,by="transcript.ID",all.x=T);'\
'data3=read.table(args[3], header=F,sep="\t"); data3=data3[,c(4,10)]; colnames(data3)=c("transcript.ID","exons");'\
'dataMerge2=merge(dataMerge,data3,by="transcript.ID",all.x=T);'\
'write.table(dataMerge2,paste(args[1],"ORF_exons",sep="."), sep="\t", quote=F, row.names=F, col.names=T);' $ann $longestORF $asmBed

## prepare a list of candidate novel genes
Rscript -e 'args=(commandArgs(TRUE)); data1=read.table(args[1],header=T,sep="\t");'\
'candidate_novels=subset(data1,class_code.x.1 %in% "u" | class_code.y.1 %in% "u" | class_code.y %in% "u" | class_code.x %in% "u");'\
'write.table(candidate_novels,paste(args[1],"candNovel",sep="."), sep="\t", quote=F, row.names=F, col.names=T);' $ann.ORF_exons
tail -n+2 $ann.ORF_exons.candNovel | wc -l # 63190
candNovel_ann=$ann.ORF_exons.candNovel
## R plot to compare the current assembly with the 4 public assemblies
bash $script_path/run_compAn.sh "$candNovel_ann" "${candNovel_ann%.merge.reduced*}.candNovel.transcriptsCompare.pdf" $script_path/compAn.R;
## R plot to assess the distribution of class codes (according to comparison with NCBI assembly) per chromosome
bash $script_path/run_compNCBIperChr.sh "$candNovel_ann" "$genome_dir/$UCSCgenome.chrom.sizes" "${candNovel_ann%.merge.reduced*}.candNovel.transCompareNCBIperChr.pdf" $script_path/compNCBI_PerCh.R;

## prepare a list of candidate novel genes that are supported by other assemblies
Rscript -e 'args=(commandArgs(TRUE)); data1=read.table(args[1],header=T,sep="\t");'\
'check=c("=","j");'\
'supporting_novels=subset(data1,class_code.x.1 %in% check | class_code.y.1 %in% check | class_code.y %in% check | class_code.x %in% check);'\
'write.table(supporting_novels,paste(args[1],"sup",sep="."), sep="\t", quote=F, row.names=F, col.names=T);'\
'unsup_novels=subset(data1,!(class_code.x.1 %in% check | class_code.y.1 %in% check | class_code.y %in% check | class_code.x %in% check));'\
'write.table(unsup_novels,paste(args[1],"unsup",sep="."), sep="\t", quote=F, row.names=F, col.names=T);' $candNovel_ann
supNovel_ann=$ann.ORF_exons.candNovel.sup
unsupNovel_ann=$ann.ORF_exons.candNovel.unsup
tail -n+2 $supNovel_ann | wc -l # 7363
tail -n+2 $supNovel_ann | awk -F $'\t' '{A[$28]++}END{for(i in A)print i,A[i]}' | sort -k2,2nr > $supNovel_ann.freq
tail -n+2 $unsupNovel_ann | wc -l # 55827
## R plot to compare the current assembly with the 4 public assemblies
bash $script_path/run_compAn.sh "$supNovel_ann" "${supNovel_ann%.merge.reduced*}.supNovel.transcriptsCompare.pdf" $script_path/compAn.R;
## R plot to assess the distribution of class codes (according to comparison with NCBI assembly) per chromosome
bash $script_path/run_compNCBIperChr.sh "$supNovel_ann" "$genome_dir/$UCSCgenome.chrom.sizes" "${supNovel_ann%.merge.reduced*}.supNovel.transCompareNCBIperChr.pdf" $script_path/compNCBI_PerCh.R;

## prepare a list of candidate novel genes that are NOT supported by other assemblies BUT supported by predicted or non horse gene models
cons=$horse_trans/consAna/$cufflinks_run.$cuffmerge_run.cons.merge.reduced
Rscript -e 'args=(commandArgs(TRUE)); data1=read.table(args[1],header=T,sep="\t");'\
'data2=read.table(args[2],header=T,sep="\t");'\
'check=c("=","j");'\
'cons=subset(data1,(augustusGene.class_code %in% check | geneid.class_code %in% check | genscan.class_code %in% check | nscanGene.class_code %in% check | transMapAlnRefSeq.class_code %in% check | xenoRefGene.class_code %in% check));'\
'novels_cons=merge(cons,data2[,c(1,27,28)],by="transcript.ID",all.x=F,all.y=F);'\
'write.table(novels_cons,paste(args[2],"cons",sep="."), sep="\t", quote=F, row.names=F, col.names=T);'\
'uncons=subset(data1,!(augustusGene.class_code %in% check | geneid.class_code %in% check | genscan.class_code %in% check | nscanGene.class_code %in% check | transMapAlnRefSeq.class_code %in% check | xenoRefGene.class_code %in% check));'\
'novels_uncons=merge(data2,data.frame(transcript.ID=uncons[,1]),by="transcript.ID",all.x=F,all.y=F);'\
'write.table(novels_uncons,paste(args[2],"uncons",sep="."), sep="\t", quote=F, row.names=F, col.names=T);' $cons $unsupNovel_ann
tail -n+2 $unsupNovel_ann.cons | wc -l # 1931
tail -n+2 $unsupNovel_ann.cons | awk -F $'\t' '{A[$32]++}END{for(i in A)print i,A[i]}' | sort -k2,2nr > $unsupNovel_ann.cons.freq
tail -n+2 $unsupNovel_ann.uncons | wc -l # 53896

## prepare a list of candidate novel genes that are NOT supported by other assemblies or predicted or non horse gene models BUT has ORF
Rscript -e 'args=(commandArgs(TRUE)); data1=read.table(args[1],header=T,sep="\t");'\
'notNA=subset(data1,!(is.na(longest_ORF)));'\
'write.table(notNA,paste(args[1],"ORF",sep="."), sep="\t", quote=F, row.names=F, col.names=T);'\
'noORF=subset(data1,is.na(longest_ORF));'\
'write.table(noORF,paste(args[1],"noORF",sep="."), sep="\t", quote=F, row.names=F, col.names=T);' $unsupNovel_ann.uncons
tail -n+2 $unsupNovel_ann.uncons.ORF | wc -l # 11414
tail -n+2 $unsupNovel_ann.uncons.ORF | awk -F $'\t' '{A[$28]++}END{for(i in A)print i,A[i]}' | sort -k2,2nr > $unsupNovel_ann.uncons.ORF.freq
tail -n+2 $unsupNovel_ann.uncons.noORF | wc -l # 42482
tail -n+2 $unsupNovel_ann.uncons.noORF | awk -F $'\t' '{A[$28]++}END{for(i in A)print i,A[i]}' | sort -k2,2nr > $unsupNovel_ann.uncons.noORF.freq

## copy the novel gene tables to the downloads
cp $supNovel_ann $unsupNovel_ann.cons $unsupNovel_ann.uncons.ORF $unsupNovel_ann.uncons.noORF $ann.*.freq $horse_trans/downloads/.
###########################################################################################
## annotation of novel genes
mkdir $horse_trans/novelGenes
cd $horse_trans/novelGenes
wget "https://data.broadinstitute.org/Trinity/Trinotate_v3_RESOURCES/Trinotate_v3.sqlite.gz" -O Trinotate.sqlite.gz
gunzip Trinotate.sqlite.gz
grep "^>" $tissue_Cuffmerge/$cuffmerge_output/filtered/transcripts.fasta | awk -F'[> ]' 'BEGIN{OFS="\t";} {print $3,$2}' > gene_trans_map_file
transdecod_path="$tissue_Cuffmerge/$cuffmerge_output/filtered/transdecoder"
for f in $supNovel_ann $unsupNovel_ann.cons $unsupNovel_ann.uncons.ORF;do  ## 20708 total 
 label=${f#$candNovel_ann.}; echo $label;
 ## make a gene to transcript map
 tail -n+2 $f | awk -F '[\t"]' '{print $1;}' | grep -F -f - -w gene_trans_map_file > $label.gene_trans_map_file
 ## isolate the novel group of transcripts
 awk -F'\t' '{print $2}' $label.gene_trans_map_file > $label.transIDs;
 bash $script_path/select_trans.sh "$tissue_Cuffmerge/$cuffmerge_output/filtered/transcripts.fasta" "$label.fasta" "$label.transIDs"
 ## run blastx search against swiss-prot datbase
 bash $script_path/run_blast.sh "$label.fasta" "$refPtn" $label."blastx.outfmt6" "$script_path/blastx.sh"
 ## isolate a list of possible ORFs in novel transcripts (This is not all possible ORFs but only the siginicant one after previous transdecoder run)
 #tail -n+2 $f | awk -F '[\t"]' '{if($(NF-1) != "NA")print $1;}' | grep -F -f - -w $transdecod_path/transcripts.fasta.transdecoder_dir/longest_orfs.pep | awk -F'[> ]' '{print $2}' >> novel_ORFs.key
 tail -n+2 $f | awk -F '[\t"]' '{if($(NF-1) != "NA")print $1;}' | grep -F -f - -w $transdecod_path/transcripts.fasta.transdecoder.genome.bed > $label.transdecoder.genome.bed ## 24151 ORF (17651 transcript)
 awk -F '[\t=;]' '{print $5}' $label.transdecoder.genome.bed > $label.ORFs.key
 bash $script_path/select_trans.sh "$transdecod_path/transcripts.fasta.transdecoder_dir/longest_orfs.pep" "$label.pep" "$label.ORFs.key"
 ## get the results of blastp and pfam search from the previous transdecoder run
 grep -w -F -f $label.ORFs.key $transdecod_path/blastp.outfmt6 > $label.blastp.outfmt6
 #cat $label.blastp.outfmt6 | sort -k1,1 -k12,12nr -k11,11n | sort -u -k1,1 --merge > $label.blastp.outfmt6.uniq ## qseqid sseqid pident length mismatch gapopen qstart qend sstart send evalue bitscore
 head -n3 $transdecod_path/pfam.domtblout > $label.pfam.domtblout
 grep -w -F -f $label.ORFs.key $transdecod_path/pfam.domtblout >> $label.pfam.domtblout
 ## generate Trinotate annotation erport
 cp Trinotate.sqlite $label.Trinotate.sqlite;
 bash $script_path/trinotate.sh $label
 awk -F'\t' 'BEGIN{OFS="\t";} {print $1,$2,$3,$6,$7,$8,$10}' $label.annotation_report.xls > $label.annotation_report_reduced.xls
 ## copy the annotations reports to the downloads
 cp $label.annotation_report_reduced.xls $horse_trans/downloads/.
 ## keep a list of novel transcripts without ORFs
 #tail -n+2 $f | awk -F '[\t"]' '{if($(NF-1) == "NA")print $1;}' >  $label.novel_noORFs.key
done
###########################################################################################
## Final filtered transcriptome
assembly="$tissue_Cuffmerge/$cuffmerge_output/filtered"
mkdir $assembly/refined
cd $assembly/refined
tail -n+2 $unsupNovel_ann.uncons.noORF | awk '{print $1}' > removeit.id
grep -v -F -w -f removeit.id $assembly/merged.gtf > merged.gtf
grep -v -F -w -f removeit.id $assembly/merged.bed > merged.bed

#Construct the transcript fasta file && calculate statistics
bash $script_path/run_genome_to_cdna_fasta.sh "merged.gtf" "$genome" "transcripts.fasta" "$script_path/genome_to_cdna_fasta.sh"
bash $script_path/run_seq_stats.sh "transcripts.fasta" "refined_transcriptome.MatzStat"
echo "no of gene: " $(cat merged.gtf | awk -F '[\t"]' '{ print $10 }' |  sort | uniq | wc -l) >> refined_transcriptome.MatzStat 
echo "no of transcripts: " $(cat merged.gtf | awk -F '[\t"]' '{ print $12 }' |  sort | uniq | wc -l) >> refined_transcriptome.MatzStat
cp refined_transcriptome.MatzStat $horse_trans/downloads/.
##########################################################################################
## merge FATSA of the refined assembly to the gene bank  assemblies and filter by read support
mkdir -p $horse_trans/mergedTrans
cd $horse_trans/mergedTrans
## run cufcompare to merge the assemblies to generate gene_trans_map for the super loci (use -C & -F to keep contained and redundant fragments)
module load cufflinks/2.2.1
refinedGTF_file=$tissue_Cuffmerge/$cuffmerge_output/filtered/refined/merged.gtf
cuffcompare -V -C -F -o "merged" $ncbiGTF_file $ensGTF_file $refinedGTF_file &> cuffcompare.log
for f in $ncbiGTF_file $ensGTF_file $refinedGTF_file;do mv $(dirname $f)/merged.$(basename $f).tmap .;done
grep "made redundant by" cuffcompare.log | awk '{print $2,$7}' | sed 's/)//g' > redundant_list ## First column is the descarded transcript
cat merged.loci | awk -F'\t' '{print $1,$4,$5,$6}' | sed 's/ -//g; s/,/ /g;' | awk '{for(i=2;i<=NF;i++){print $1,$i;}}' > gene_transcript_map.nonRedundant
join -j2 -o 2.1,1.1 <(sort -k 2b,2 redundant_list) <(sort -k 2b,2 gene_transcript_map.nonRedundant) > gene_transcript_map.Redundant
cat gene_transcript_map.nonRedundant gene_transcript_map.Redundant > gene_transcript_map 

wget ftp://ftp.ncbi.nih.gov/genomes/Equus_caballus/RNA/rna.fa.gz -O NCBI.fa.gz
gunzip NCBI.fa.gz
cat NCBI.fa | awk '/^>/ {if(N>0) printf("\n"); printf("%s\n",$0);N++;next;} {printf("%s",$0);} END {if(N>0) printf("\n");}' > NCBI_unwrap.fasta
sed -i 's/>gi|.*|ref|/>/g; s/|//g' NCBI_unwrap.fasta 
cat $ncbiGTF_file | awk -F '[\t"]' '{ print $12 }' |  sort | uniq > ncbi_gtf.ids
grep "^>" NCBI_unwrap.fasta | awk -F'[> ]' '{print $2}' | sort > ncbi_fasta.ids
comm -23 ncbi_gtf.ids ncbi_fasta.ids > ncbi_remaining.ids
grep -F -w -f ncbi_remaining.ids $ncbiGTF_file > ncbi_remaining.gtf
bash $script_path/run_genome_to_cdna_fasta.sh "ncbi_remaining.gtf" "$genome" "NCBI_remaining.fasta" "$script_path/genome_to_cdna_fasta.sh"
bash $script_path/run_genome_to_cdna_fasta.sh "$ensGTF_file" "$genome" "ensembl.fasta" "$script_path/genome_to_cdna_fasta.sh"
cp $tissue_Cuffmerge/$cuffmerge_output/filtered/refined/transcripts.fasta refinedTrans.fasta
cat *.fasta > allTrans.fa
#qsub -v index="allTrans_index",transcriptome="allTrans.fa" ${script_path}/salmonIndex.sh
bash $script_path/run_salmonIndex.sh "allTrans_index" "allTrans.fa" ${script_path}/salmonIndex.sh
while read work_dir; do
  lib=$(basename $work_dir | cut -d"_" -f 1)                      ## PE or SE
  strand=$(basename $work_dir | cut -d"_" -f 3 | sed 's/\./-/')   ## fr-unstranded, fr-firststrand or fr-secondstrand
  identifier=$(echo $work_dir | rev | cut -d"/" -f 1,2 | rev | sed 's/\//_/')
  seq_dir=$work_dir/trimmed_RNA_reads
  bash ${script_path}/run_salmon.sh "$lib" "$strand" "allTrans_index" "$identifier" "$seq_dir" "$script_path"
done < $horse_trans/working_list.txt
find ./*.quant -name \*.sf -exec grep -H "mapping rate" {} \; | sort > salmonQuant_summary.txt
python $script_path/gather-counts.py -i "$(pwd)"
echo "transcript"$'\t'"length" > transcripts.lengthes
sf=$(find ./*.quant -name \*.sf | head -n1)
cat $sf | grep -v "^#" | awk -F "\t" -v OFS='\t' '{print $1,$2}' >> transcripts.lengthes

identifier="" ## leave the identifier empty if you want to calculate TPM for all files
bash $script_path/run_calcTPM.sh "$(pwd)" "$identifier" "transcripts.lengthes" "gene_transcript_map" ${script_path}/calcTPM2.R
cat dataSummary_comp | tail -n+2 | awk '{if($7 >= 0.1 && $10 >= 5)print $3}' > keepit.id
grep  "^[NX]\|^rna" keepit.id > ncbi.keepit.id
grep "^ENSECAT" keepit.id > ens.keepit.id
grep "^TCONS" keepit.id > refined.keepit.id
wc -l *.keepit.id

grep -F -w -f ncbi.keepit.id $ncbiGTF_file > new_ncbi.gtf
grep -F -w -f ens.keepit.id $ensGTF_file > new_ens.gtf
grep -F -w -f refined.keepit.id $refinedGTF_file > new_refined.gtf

for f in ncbiGTF_file ensGTF_file refinedGTF_file;do
 echo $f
 cat ${!f} | awk -F '[\t"]' '{ print $10 }' |  sort | uniq | wc -l ## no of gene 
 cat ${!f} | awk -F '[\t"]' '{ print $12 }' |  sort | uniq | wc -l ## no of trans 
done > mergeTrans.summary

for f in new_*.gtf;do
 echo $f
 cat ${f} | awk -F '[\t"]' '{ print $10 }' |  sort | uniq | wc -l ## no of gene 
 cat ${f} | awk -F '[\t"]' '{ print $12 }' |  sort | uniq | wc -l ## no of trans 
done >> mergeTrans.summary

module load cufflinks/2.2.1
cat new_ncbi.gtf new_ens.gtf new_refined.gtf > mergeTrans.gtf
cuffcompare -T -V -o "mergeTrans" mergeTrans.gtf &> cuffcompare.log2
grep "made redundant by" cuffcompare.log2 | awk '{print $2,$7}' | sed 's/)//g' > redundant_list2 ## First column is the descarded transcript
grep  "^[NX]\|^rna" redundant_list2 > ncbi.redundant
grep "^ENSECAT" redundant_list2 > ens.redundant
grep "^TCONS" redundant_list2 > refined.redundant
for f in *.redundant; do
 wc -l $f
 echo "made redundant by ncbi: " $(awk '{print $2}' $f | grep "^[NX]\|^rna" | wc -l)
 echo "made redundant by ensembl: " $(awk '{print $2}' $f | grep "^ENSECAT" | wc -l)
 echo "made redundant by refined Transcriptome: " $(awk '{print $2}' $f | grep "^TCONS" | wc -l)
done > redundancy_report

awk '{print $1}' redundant_list2 | grep -v -F -w -f - mergeTrans.gtf > mergeTrans_nonRedundant.gtf

## create hub for meregd track
## create list of assemblies
> merged_assemblies.txt
echo "$horse_trans" "mergedTrans" > tissue_assemblies.txt;
## convert the gtf files into BigBed files & copy the BigBed files to the track hub directory
targetAss=$"mergeTrans_nonRedundant.gtf"
bash $script_path/gtfToBigBed.sh "$targetAss" "$genome_dir/$UCSCgenome.chrom.sizes" "$script_path"
identifier="mergedTrans"
cp *.BigBed $track_hub/$UCSCgenome/BigBed/${identifier}.BigBed

hub_name=$"HorseTrans_MergedAsm"
shortlabel=$"MergedAsm"
longlabel=$"Merge of all public assemblies"
email=$"drtamermansour@gmail.com"
cd $track_hub
bash $script_path/create_trackHub.sh "$UCSCgenome" "$hub_name" "$shortlabel" "$longlabel" "$email"

## edit the trackDb
current_libs=$track_hub/current_libs_$shortlabel
current_tissues=$track_hub/current_tiss_$shortlabel
trackDb=$track_hub/$UCSCgenome/trackDb_$shortlabel.txt
lib_assemblies=$horse_trans/mergedTrans/merged_assemblies.txt
tiss_assemblies=$horse_trans/mergedTrans/tissue_assemblies.txt
bash $script_path/edit_trackDb.sh $current_libs $current_tissues $trackDb $lib_assemblies $tiss_assemblies
###########################################################################################
## correct the assembled trascriptome to fix genome errors
bash ${script_path}/main-variantAnalysis.gvcfMode.sh
cp $assembly/varFixed/transcripts.fasta $horse_trans/downloads/varFixed_Transcriptome.fa

###########################################################################################
## run Transdecoder to predict UTRs with homology options
#sample_list="$horse_trans/Tophat_${cufflinks_run}_${cuffmerge_run}_assemblies.txt"
#bash $script_path/run_transdecoder.sh $sample_list $genome $refPtn $refPfam $script_path/transdecoder.sh
mkdir $assembly/varFixed/transdecoder
cd $assembly/varFixed/transdecoder
cp ../transcripts.fasta .
# extract the long open reading frames
bash $script_path/run_getLongORFs.sh "transcripts.fasta" "$script_path/getLongORFs.sh"
## identify ORFs with homology to known proteins via blast and pfam searches.
mkdir tempPep && cd tempPep
cp ../transcripts.fasta.transdecoder_dir/longest_orfs.pep .
$script_path/splitFasta.pl longest_orfs.pep 50
for pep in subset10[a-b]_longest_orfs.pep;do
  label=${pep%_longest_orfs.pep}
#  bash $script_path/run_blast.sh "$pep" "$refPtn" $label."blastp.outfmt6" "$script_path/blastp.sh"
  bash $script_path/run_hmmscan.sh "$pep" "$refPfam" $label."pfam.domtblout" "$script_path/hmmscan.sh"
done
cat subset*.blastp.outfmt6 >> ../blastp.outfmt6
cat subset*.pfam.domtblout >> ../pfam.domtblout
## predict the likely coding regions
cd ../
bash $script_path/run_transdecoderPredict.sh "transcripts.fasta" "pfam.domtblout" "blastp.outfmt6" "$script_path/transdecoderPredict.sh"
# create an alignment-GFF3 formatted file
$script_path/decoderUtil/cufflinks_gtf_to_alignment_gff3.pl "../varFixed_best.gtf" > transcripts.gff3
# generate a genome-based coding region annotation file
$script_path/cdna_alignment_orf_to_genome_orf.pl transcripts.fasta.transdecoder.gff3 transcripts.gff3 transcripts.fasta 1> transcripts.fasta.transdecoder.genome.gff3 2> sterr
grep "Warning" sterr > warnings.txt && rm sterr
# convert the genome-based gene-gff3 file to bed
$script_path/decoderUtil/gff3_file_to_bed.pl transcripts.fasta.transdecoder.genome.gff3 > transcripts.fasta.transdecoder.genome.bed
## exclude transcripts with single exon for better visualization
#cat transcripts.fasta.transdecoder.genome.bed | awk '$10 > 1' > transcripts.fasta.transdecoder.genome.multiexon.bed

tail -n+2 transcripts.fasta.transdecoder.bed | awk -F '\t' '{print $1}' > Trans_ID
tail -n+2 transcripts.fasta.transdecoder.bed | awk -F '[\t:]' '{print $6}' | awk -F '_' '{print $1}' > ORF_len
paste Trans_ID ORF_len > all_ORFs
sort -k1,1 -k2,2rg all_ORFs | sort -u -k1,1 --merge > longest_ORFs
join $assembly/transdecoder/longest_ORFs $assembly/varFixed/transdecoder/longest_ORFs > compare_fixation
cat compare_fixation | awk '$3>$2' > increased_list   ## 472
cat compare_fixation | awk '($3-$2)>1' | wc -l ## 428

cat compare_fixation | awk '$3<$2' > decreased_list   ## 291
join -v1 $assembly/transdecoder/longest_ORFs $assembly/varFixed/transdecoder/longest_ORFs > uniqforUnfixed   ## 188
join -v2 $assembly/transdecoder/longest_ORFs $assembly/varFixed/transdecoder/longest_ORFs > uniqforFixed  ## 176

cat increased_list uniqforFixed | awk '{print "ID="$1"|"}' > increase_keys  ## 648
cat decreased_list uniqforUnfixed | awk '{print "ID="$1"|"}' > decrease_keys  ## 479

## check for the increase_keys in the new assembly while check for decrease_keys in the old assembly
grep -F -f increase_keys transcripts.fasta.transdecoder.genome.bed > increase_keys.transdecoder.genome.bed
cat increase_keys.transdecoder.genome.bed | awk '$10 == 1' > increase_keys.transdecoder.genome.Singleexon.bed
cat increase_keys.transdecoder.genome.bed | awk '$10 > 1' > increase_keys.transdecoder.genome.multiexon.bed
cat increase_keys.transdecoder.genome.bed | awk -F '[\t=|]' '{print $5}' | sort | uniq | wc -l ## 562
cat increase_keys.transdecoder.genome.Singleexon.bed | awk -F '[\t=|]' '{print $5}' | sort | uniq | wc -l ## 112
cat increase_keys.transdecoder.genome.multiexon.bed | awk -F '[\t=|]' '{print $5}' | sort | uniq | wc -l ## 450

grep -F -f decrease_keys $assembly/transdecoder/transcripts.fasta.transdecoder.genome.bed > decrease_keys.transdecoder.genome.bed
cat decrease_keys.transdecoder.genome.bed | awk '$10 == 1' > decrease_keys.transdecoder.genome.Singleexon.bed
cat decrease_keys.transdecoder.genome.bed | awk '$10 > 1' > decrease_keys.transdecoder.genome.multiexon.bed
cat decrease_keys.transdecoder.genome.bed | awk -F '[\t=|]' '{print $5}' | sort | uniq | wc -l ## 452
cat decrease_keys.transdecoder.genome.Singleexon.bed | awk -F '[\t=|]' '{print $5}' | sort | uniq | wc -l ## 252
cat decrease_keys.transdecoder.genome.multiexon.bed | awk -F '[\t=|]' '{print $5}' | sort | uniq | wc -l ## 200

## calculate the phase of Transdecoder GFF3 files
#while read assembly; do if [ -f $assembly/transdecoder/transcripts.fasta.transdecoder.genome.gff3 ];then
#  echo $assembly
#  cd $assembly/transdecoder
#  bash $script_path/cdsphase.sh transcripts.fasta.transdecoder.genome.gff3
#fi; done < $horse_trans/Tophat_${cufflinks_run}_${cuffmerge_run}_assemblies.txt
#######################
## create list of assemblies
## This is where you can edit the list to restrict the processing for certain target(s)
rm -f $tissue_Cuffmerge/decoder_assemblies.txt
echo "$tissue_Cuffmerge/$cuffmerge_output/filtered" "transdecoder" >> $tissue_Cuffmerge/decoder_assemblies.txt
echo "$tissue_Cuffmerge/$cuffmerge_output/filtered" "varFixed/transdecoder" >> $tissue_Cuffmerge/decoder_assemblies.txt
####################
## convert the gtf files into BigBed files & copy the BigBed files to the track hub directory
update=1    ## 0 means do not update Bigbed files & 1 means update
rm -f $horse_trans/decoder_assemblies.txt
while read ass_path assembly; do
  echo $assembly
  if [ -d "$ass_path/$assembly" ];then
    cd $ass_path/$assembly
  else echo "can not find $ass_path/$assembly"; break;fi
  if [[ ! -f "*.BigBed" || "$update" -eq 1 ]];then
    #targetAss=$"transcripts.fasta.transdecoder.genome.multiexon.bed"
    targetAss=$"transcripts.fasta.transdecoder.genome.bed"
    if [ -f "$targetAss" ];then
      bash $script_path/bedToBigBed.sh "$targetAss" "$genome_dir/$UCSCgenome.chrom.sizes"
    else echo "can not find the target BED file"; break;fi
    if [ -f ${targetAss%.bed}.BigBed ];then
      identifier=$(echo $assembly | sed 's/\//_/g' | sed 's/_output//g')
      cp ${targetAss%.bed}.BigBed $track_hub/$UCSCgenome/BigBed/${identifier}.BigBed
    else echo "could not make BigBed file"; break; fi
  fi
  echo $ass_path/$assembly >> $horse_trans/decoder_assemblies.txt;
done < $tissue_Cuffmerge/decoder_assemblies.txt
#########################
## initiate a given track hub
hub_name=$"HorseTrans2"
shortlabel=$"TopCuffmerge_TD"
longlabel=$"Single samlpe ref guided Tophat/Cufflinks followed by Cuffmerge/transdecoder"
email=$"drtamermansour@gmail.com"
cd $track_hub
bash $script_path/create_trackHub.sh "$UCSCgenome" "$hub_name" "$shortlabel" "$longlabel" "$email"

## edit the trackDb
current_libs=$track_hub/current_libs_$shortlabel
current_tissues=$track_hub/current_tiss_$shortlabel
trackDb=$track_hub/$UCSCgenome/trackDb_$shortlabel.txt
#lib_assemblies=$prepData/merged_decoder_assemblies.txt
lib_assemblies=$horse_trans/emptyTemp.txt
tiss_assemblies=$tissue_Cuffmerge/decoder_assemblies.txt
bash $script_path/edit_trackDb.sh $current_libs $current_tissues $trackDb $lib_assemblies $tiss_assemblies
###########################################################################################
###########################################################################################
###########################################################################################
###########################################################################################
## pipeline_diginormAllsamples_mergeSamples_Tophat2.nonGuided_Cufflinks
bash ${script_path}/main-DigiTopHatCufflinks_pipline_multi.sh

###########################################################################################
## run icommand to push the file to iplant
## https://pods.iplantcollaborative.org/wiki/display/DS/Using+iCommands
## http://bioinformatics.plantbiology.msu.edu/display/IP/Moving+Data+from+HPCC+to+iPlant
## copy the required files to home directory e.g. ~/temp/download
## make sure you are on the gateway not on a dev-nodes
iinit
icd /iplant/home/drtamermansour/horseTrans
iput *.reduced .

