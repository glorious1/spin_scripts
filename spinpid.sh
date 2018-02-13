#!/usr/local/bin/bash
# spinpid.sh for Supermicro boards with single fan zone
VERSION="2018-01-01"
# Run as superuser. See notes at end.

##############################################
#
#  Settings
#
##############################################

# Creates logfile and sends all stdout and stderr to the log, as well as to the console.
# If you want to append to existing log, add '-a' to the tee command.
# Change to your desired log location/name:
LOG=/mnt/Ark/Jim/spinpid.log
exec > >(tee -i $LOG) 2>&1

DUTY_MIN=20  # Fan minimum duty cycle (%) (to avoid stalling)

#################  DRIVE SETTINGS ################

SP=33.57        #  Setpoint mean drive temperature (C)

#  Time interval for checking drives (minutes).  Drives change
#  temperature slowly; 5 minutes is probably frequent enough.
DRIVE_T=5
Kp=4    #  Proportional tunable constant (for drives)
Ki=0    #  Integral tunable constant (for drives)
Kd=40   #  Derivative tunable constant (for drives)

#################  CPU SETTINGS ################

#  Time interval for checking CPU (seconds).
#  1 to 12 may be appropriate.
CPU_T=6

#  Reference temperature (C) for scaling CPU_DUTY (NOT a setpoint).
#  At and below this temperature, CPU will demand minimum
#  fan speed (DUTY_MIN above).
CPU_REF=55  # Integer only!
#  Scalar for scaling CPU_DUTY.
#  CPU will demand this number of percentage points in additional
#  duty cycle for each degree of temperature above CPU_REF.
CPU_SCALE=6  # Integer only!

##############################################
# function get_disk_name
# Get disk name from current LINE of DEVLIST
##############################################
# The awk statement works by taking $LINE as input,
# setting '(' as a _F_ield separator and taking the second field it separates
# (ie after the separator), passing that to another awk that uses
# ',' as a separator, and taking the first field (ie before the separator).
# i.e., everything between '(' and ',' is kept.

# camcontrol output for disks on HBA seems to change every version,
# so need 2 options to get ada/da disk name.
function get_disk_name {
   if [[ $LINE == *",p"* ]] ; then     # for ([a]da#,pass#)
      DEVID=$(echo "$LINE" | awk -F '(' '{print $2}' | awk -F ',' '{print$1}')
   else                                # for (pass#,[a]da#)
      DEVID=$(echo "$LINE" | awk -F ',' '{print $2}' | awk -F ')' '{print$1}')
   fi
}

############################################################
# function print_header
# Called when script starts and each quarter day
############################################################
function print_header {
   DATE=$(date +"%A, %b %d")
   let "SPACES = DEVCOUNT * 5 + 57"  # 5 spaces per drive
   printf "\n%-*s %-8s %21s \n" $SPACES "$DATE" "Fan %" "Interim"
   echo -n "          "
   while read -r LINE ; do
      get_disk_name
      printf "%-5s" "$DEVID"
   done <<< "$DEVLIST"             # while statement works on DEVLIST
   printf "%4s %5s %5s %6s %5s %6s %3s %s %4s %-8s %4s %s" "Tmax" "Tmean" "ERRc" "P" "I" "D" "CPU" "Driver" "Prev/New" "MODE" "RPM" "Adjustments"
}

#################################################
# function read_fan_data
#################################################
function read_fan_data {
   # Read duty cycle
   DUTY_CURR=$($IPMITOOL raw 0x30 0x70 0x66 0 0) # in hex with leading space
   # Following doesn't work if $DUTY_CURR is double quoted
   DUTY_CURR=$((0x$(echo $DUTY_CURR)))  # echoing trims leading space, then decimalize
   # Read fan mode
   MODE=$($IPMITOOL raw 0x30 0x45 0) # in hex
   MODE=$((0x$(echo $MODE)))  # strip leading space and decimalize
   # Text for mode
   case $MODE in
      0) MODEt="Standard" ;;
      4) MODEt="HeavyIO" ;;
      2) MODEt="Optimal" ;;
      1) MODEt="Full" ;;
   esac
   # Get reported fan speed in RPM.
   # Takes the line with FAN1, then 2nd through the 5th
   # digit if there are that many.
   RPM=$($IPMITOOL sdr | grep "FAN1" | grep -Eo '[0-9]{2,5}')
}

##############################################
# function CPU_check_adjust
# Get CPU temp. Calculate a new DUTY_CPU.
# If it is greater than the duty due to the
# drives, send it to adjust_fans.
##############################################
function CPU_check_adjust {
   #   Old methods of checking CPU temp:
   #   CPU_TEMP=$($IPMITOOL sdr | grep "CPU Temp" | grep -Eo '[0-9]{2,5}')
   #   CPU_TEMP=$($IPMITOOL sensor get "CPU Temp" | awk '/Sensor Reading/ {print $4}')
   
   # Find hottest CPU core
   MAX_CORE_TEMP=0
   for CORE in $(seq 0 $CORES)
   do
       CORE_TEMP="$(sysctl -n dev.cpu.${CORE}.temperature | awk -F '.' '{print$1}')"
       if [[ $CORE_TEMP -gt $MAX_CORE_TEMP ]]; then MAX_CORE_TEMP=$CORE_TEMP; fi
   done
   CPU_TEMP=$MAX_CORE_TEMP

   DUTY_CPU=$( constrain $(( (CPU_TEMP - CPU_REF) * CPU_SCALE + DUTY_MIN )) )
   
   if [[ FIRST_TIME -eq 1 ]]; then return; fi
   
   local NEW=$DUTY_CPU
#   local SOURCE="C"
   local DUTY_PREV=$DUTY_CURR

   # This allows fans to come down faster after high CPU demand.
   # Adjust DUTY_DRIVE if it will go down (PID<0) and drives are cool
   # (Tmean<<SP), otherwise changes are not good.
   if [[ PID -lt 0 && (( $(bc -l <<< "$Tmean < $SP-1") == 1 )) ]]; then
      DUTY_DRIVE=$( constrain $(( DUTY_CURR + PID )) )
   fi

#   NEW=$(( DUTY_DRIVE > DUTY_CPU ? DUTY_DRIVE : DUTY_CPU ))  # take max
	if [[ DUTY_DRIVE -gt DUTY_CPU ]]; then
		NEW=$DUTY_DRIVE
#		SOURCE="D"
	fi

   adjust_fans "$NEW"  # sets DUTY_CURR

   # DIAGNOSTIC variables - uncomment for troubleshooting:
   # printf "\nDUTY_DRIVE=%s, CPU_TEMP=%s, DUTY_CPU=%s, DUTY_CURR=%s  " "${DUTY_DRIVE:---}" "${CPU_TEMP:---}" "${DUTY_CPU:---}" "${DUTY_CURR:---}"

   if [[ DUTY_PREV -ne DUTY_CURR ]]; then
#      printf "%s%d " $SOURCE $DUTY_CURR
      printf "%d " $DUTY_CURR
   fi
}

##############################################
# function DRIVES_check_adjust
# Print time on new log line.
# Go through each drive, getting and printing
# status and temp.  Calculate sum and max
# temp, then call function drive_data.
# Apply max of $PID and CPU_CORR to the fans.
##############################################
function DRIVES_check_adjust {
   echo  # start new line
   # print time on each line
   TIME=$(date "+%H:%M:%S"); echo -n "$TIME  "
   Tmax=0; Tsum=0  # initialize drive temps for new loop through drives
   i=0  # count number of spinning drives
   while read -r LINE ; do
      get_disk_name
      /usr/local/sbin/smartctl -a -n standby "/dev/$DEVID" > /var/tempfile
      RETURN=$?  # have to preserve return value or it changes
      BIT0=$((RETURN & 1))
      BIT1=$((RETURN & 2))
      if [ $BIT0 -eq 0 ]; then
         if [ $BIT1 -eq 0 ]; then  # spinning
            STATUS="*"
         else  # drive found but no response, probably standby
            STATUS="_"
         fi
      else   # smartctl returns 1 (00000001) for missing drive
         STATUS="?"
      fi

      TEMP=""
      # Update temperatures each drive; spinners only
      if [ "$STATUS" == "*" ] ; then
         # Taking 10th space-delimited field for WD, Seagate, Toshiba, Hitachi
         TEMP=$( grep "Temperature_Celsius" /var/tempfile | awk '{print $10}')
         let "Tsum += $TEMP"
         if [[ $TEMP > $Tmax ]]; then Tmax=$TEMP; fi;
         let "i += 1"
      fi
      printf "%s%-2d  " "$STATUS" "$TEMP"
   done <<< "$DEVLIST"

   # if no fans are spinning
   if [ $i -eq 0 ]; then
      Tmean=""; Tmax=""; P=""; D=""
      DUTY_DRIVE=$DUTY_MIN
   else
      # summarize, calculate PID
      Tmean=$(echo "scale=2; $Tsum / $i" | bc)
		ERRp=$ERRc
		ERRc=$(echo "scale=3; ($Tmean - $SP) / 1" | bc)
		ERR=$(echo "scale=2; $ERRc * $DRIVE_T + $I" | bc)
		P=$(echo "scale=3; ($Kp * $ERRc) / 1" | bc)
		P=$(printf %0.2f "$P") # add leading 0 if needed, 2 dec. places
		I=$(echo "scale=2; ($Ki * $ERR) / 1" | bc)
		D=$(echo "scale=4; $Kd * ($ERRc - $ERRp) / $DRIVE_T" | bc)
		D=$(printf %0.2f "$D") # add leading 0 if needed, 2 dec. places
		PID=$(echo "$P + $I + $D" | bc)  # add 3 corrections
		PID=$(printf %0.f "$PID")  # round

		# add leading 0 if needed, round for printing
		Tmean=$(printf %0.2f "$Tmean")
		ERRc=$(printf %0.2f "$ERRc")
		P=$(printf %0.2f "$P")
		D=$(printf %0.2f "$D")
		PID=$(printf %0.f "$PID")

		DUTY_DRIVE=$( constrain $(( DUTY_CURR + PID )) )
   fi
   
   if [[ $DUTY_DRIVE -ge $DUTY_CPU ]]; then
      adjust_fans "$DUTY_DRIVE"
      DRIVER="Drives"
   else
      DRIVER="CPU"
   fi

   # print current Tmax, Tmean
   printf "^%-3s %5s" "${Tmax:---}" "${Tmean:----}"
}

##############################################
# function constrain
# Constrain passed duty and return it
##############################################
function constrain {
   local DUTY=$1
   # Don't allow duty cycle beyond $DUTY_MIN/95%
   if [[ $DUTY -gt 95 ]]; then DUTY=95; fi
   if [[ $DUTY -lt $DUTY_MIN ]]; then DUTY=$DUTY_MIN; fi
   echo "$DUTY"
}

##############################################
# function adjust_fans
# Constrain passed duty, then set if different
##############################################
function adjust_fans {
   local DUTY_NEW=$1
   
   # Change if different from current duty
   if [[ $DUTY_NEW -ne $DUTY_CURR ]]; then
      # Set new duty cycle. "echo -n ``" prevents newline generated in log
      echo -n "$($IPMITOOL raw 0x30 0x70 0x66 1 0 "$DUTY_NEW")"
      DUTY_CURR=$DUTY_NEW
   fi
}

#####################################################
# SETUP
# All this happens only at the beginning
# Initializing values, list of drives, print header
#####################################################
# Print settings at beginning of log
printf "\n****** SETTINGS ******\n"
printf "Drive temperature setpoint (C): %s\n" $SP
printf "Kp=%s, Ki=%s, Kd=%s\n" $Kp $Ki $Kd
printf "Drive check interval (main cycle; minutes): %s\n" $DRIVE_T
printf "CPU check interval (seconds): %s\n" $CPU_T
printf "CPU reference temperature (C): %s\n" $CPU_REF
printf "CPU scalar: %s\n" $CPU_SCALE
printf "Fan minimum duty cycle: %s\n" $DUTY_MIN

# Get number of CPU cores to check for temperature
# -1 because numbering starts at 0
CORES=$(($(sysctl -n hw.ncpu)-1))

CPU_LOOPS=$( echo "$DRIVE_T * 60 / $CPU_T" | bc )  # Number of whole CPU loops per drive loop
IPMITOOL=/usr/local/bin/ipmitool
I=0; ERRc=0  # Initialize errors to 0
FIRST_TIME=1

# Get list of drives
DEVLIST1=$(/sbin/camcontrol devlist)
# Remove lines with flash drives or SSD; edit as needed
# You could use another strategy, e.g., find something in the camcontrol devlist
# output that is unique to the drives you want, for instance only WDC drives:
# if [[ $LINE != *"WDC"* ]] . . .
DEVLIST="$(echo "$DEVLIST1"|sed '/KINGSTON/d;/ADATA/d;/SanDisk/d;/OCZ/d;/LSI/d;/INTEL/d;/TDKMedia/d;/SSD/d')"
DEVCOUNT=$(echo "$DEVLIST" | wc -l)

read_fan_data   # get fan status before making any adjustments

# If mode not full, set it to avoid BMC changing duty cycle
# Need to wait a tick or it may not get next command
# "echo -n" to avoid annoying newline generated in log
if [[ MODE -ne 1 ]]; then
   echo -n "$($IPMITOOL raw 0x30 0x45 1 1)"; sleep 1
   echo -n "$($IPMITOOL raw 0x30 0x70 0x66 1 0 50)"; sleep 1
fi

# DUTY_DRIVE NEEDS initial value.  Use DUTY_CURR unless it is
# very high and would take a long time to equilibrate.
# (or doesn't exist; second test true if it exists)
if [[ $DUTY_CURR -lt 50 && -n ${DUTY_CURR+x} ]]; then
   DUTY_DRIVE=$DUTY_CURR
else
   DUTY_DRIVE=50
fi

# Before starting, go through the drives to report if
# smartctl return value indicates a problem (>2).
# Use -a so that all return values are available.
while read -r LINE ; do
   get_disk_name
   /usr/local/sbin/smartctl -a -n standby "/dev/$DEVID" > /var/tempfile
   if [ $? -gt 2 ]; then
      printf "\n"
      printf "*******************************************************\n"
      printf "* WARNING - Drive %-4s has a record of past errors,   *\n" "$DEVID"
      printf "* is currently failing, or is not communicating well. *\n"
      printf "* Use smartctl to examine the condition of this drive *\n"
      printf "* and conduct tests. Status symbol for the drive may  *\n"
      printf "* be incorrect (but probably not).                    *\n"
      printf "*******************************************************\n"
   fi
done <<< "$DEVLIST"

printf "\n%s %51s %s \n" "Key to drive status symbols:  * spinning;  _ standby;  ? unknown" "Version" $VERSION
print_header
CPU_check_adjust

###########################################
# Main loop through drives every DRIVE_T minutes
# and CPU every CPU_T seconds
###########################################
while true ; do
   # Print header every quarter day.  Expression removes any
   # leading 0 so it is not seen as octal
   HM=$(date +%k%M)
#   HM=$((10#$HM))  # works in terminal but not in script ??
   HM=$( echo $HM | awk '{print $1 + 0}' )
   R=$(( HM % 600 ))  # remainder after dividing by 6 hours
   if (( R < DRIVE_T )); then
      print_header;
   fi

   DUTY_PREV=$DUTY_CURR
   DRIVES_check_adjust

   printf "%6s %6s %5s %6.6s %3d %-6s %2d/%-5d " "${ERRc:----}" "${P:----}" $I "${D:----}" "$CPU_TEMP" $DRIVER "$DUTY_PREV" "$DUTY_CURR"
   
   if [[ $FIRST_TIME -eq 0 ]]; then 
   	sleep 5
   	read_fan_data
   fi
   
   FIRST_TIME=0

   printf "%-8s %4d " $MODEt "$RPM"

   i=0
   while [ $i -lt "$CPU_LOOPS" ]; do
      CPU_check_adjust
      sleep $CPU_T
      let i=i+1
   done
done

# For SuperMicro motherboards with one fan zone.  
# Adjusts fans based on drive and CPU temperatures.
# Includes disks on motherboard and on HBA.
# The script compares the cooling demand of drives and
# CPU and uses whichever is greater.
# Mean drive temp is maintained at a setpoint using a PID algorithm.  
# CPU temp need not and cannot be maintained at a setpoint, 
# so PID is not used; instead fan duty cycle demand is simply
# increased with temp using reference and scale settings.

# Drives are checked and fans adjusted on a set interval, such as 5 minutes.
# Logging is done at that point.  CPU temps can spike much faster,
# so are checked and logged at a shorter interval, such as 1-15 seconds.
# CPUs with high TDP probably require short intervals.

# Logs:
#   - Disk status (* spinning or _ standby)
#   - Disk temperature (Celsius) if spinning
#   - Max and mean disk temperature
#   - Temperature error and PID variables
#   - CPU temperature
#   - Previous and new duty cycle
#   - Fan mode (should always be FULL after first line)
#   - RPM for FAN1 after new duty cycle
#   - Interim adjustments due to CPU demand

#  Relation between percent duty cycle, hex value of that number,
#  and RPMs for my fans.  RPM will vary among fans, is not
#  precisely related to duty cycle, and does not matter to the script.
#  It is merely reported.
#
#  Percent      Hex         RPM
#  10         A     300
#  20        14     400
#  30        1E     500
#  40        28     600/700
#  50        32     800
#  60        3C     900
#  70        46     1000/1100
#  80        50     1100/1200
#  90        5A     1200/1300
# 100        64     1300

# Because some Supermicro boards report incorrect duty cycle,
# you have the option of not reading that, assuming it is what we set.

# Tuning suggestions
# PID tuning advice on the internet generally does not work well in this application.
# First run the script spincheck.sh and get familiar with your temperature and fan variations without any intervention.
# Choose a setpoint that is an actual observed Tmean, given the number of drives you have.  It should be the Tmean associated with the Tmax that you want.
# Set Ki=0 and leave it there.  You probably will never need it.
# Start with Kp low.  Use a value that results in a rounded correction=1 when error is the lowest value you observe other than 0  (i.e., when ERRc is minimal, Kp ~= 1 / ERRc)
# Set Kd at about Kp*10
# Get Tmean within ~0.3 degree of SP before starting script.
# Start script and run for a few hours or so.  If Tmean oscillates (best to graph it), you probably need to reduce Kd.  If no oscillation but response is too slow, raise Kd.
# Stop script and get Tmean at least 1 C off SP.  Restart.  If there is overshoot and it goes through some cycles, you may need to reduce Kd.
# If you have problems, examine PK and PD in the log and see which is messing you up.  If all else fails you can try Ki. If you use Ki, make it small, ~ 0.1 or less.

# Uses joeschmuck's smartctl method for drive status (returns 0 if spinning, 2 in standby)
# https://forums.freenas.org/index.php?threads/how-to-find-out-if-a-drive-is-spinning-down-properly.2068/#post-28451
# Other method (camcontrol cmd -a) doesn't work with HBA
