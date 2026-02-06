#include <stdio.h>
#include <math.h>

// This function calculates the distance between the current attempt and the profile
// length: the number of data points (e.g., 20 for a 10-character password)
float calculate_distance(float* attempt, float* profile, int length) {
    float sum = 0.0;
    
    for(int i = 0; i < length; i++) {
        // Find the difference for each specific dwell or flight timing
        float diff = attempt[i] - profile[i];
        
        // Square the difference to eliminate negative values
        sum += diff * diff; 
    }
    
    // The square root gives us the actual "Straight Line" distance
    return sqrt(sum); 
}