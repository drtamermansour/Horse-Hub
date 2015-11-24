#!/bin/bash -login
#PBS -l walltime=48:00:00,nodes=1:ppn=8,mem=24Gb
#mdiag -A ged
#PBS -m abe
#PBS -N haplotypeCaller_multi

module load GATK/3.4.46

cd $PBS_O_WORKDIR

java -Xmx10g -jar $GATK/GenomeAnalysisTK.jar \
-T HaplotypeCaller \
-R $gatk_ref \
$(echo $samples) \
--dbsnp $snps \
-dontUseSoftClippedBases \
-stand_call_conf 20.0 \
-stand_emit_conf 20.0 \
--minPruning 10 \
-ploidy 2 \
-maxNumHaplotypesInPopulation 128 \
-nct 7 \
-o HC_output_ploidy2_haploAll.vcf

qstat -f ${PBS_JOBID}

















