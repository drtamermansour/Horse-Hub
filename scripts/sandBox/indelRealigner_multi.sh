#!/bin/bash -login
#PBS -l walltime=02:00:00,nodes=1:ppn=2,mem=48Gb
#mdiag -A ged
#PBS -m abe
#PBS -N indelRealigner

module load GATK/3.4.46

cd $PBS_O_WORKDIR

java -Xmx42g -jar $GATK/GenomeAnalysisTK.jar \
-T IndelRealigner \
-R "$gatk_ref" \
$(echo $samples) \
-targetIntervals gatk.intervals \
-nWayOut '.realigned.bam' \
-known "$indels" \
-model USE_SW \
-LOD 0.4

qstat -f ${PBS_JOBID}